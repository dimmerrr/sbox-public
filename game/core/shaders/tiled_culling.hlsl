//
// Structs and functions for use in culling shaders.
//

#define CULLING_TILE_SIZE 32

//--------------------------------------------------------------------------------------

class Plane
{
    float3 Normal;
    float  Distance;

    //--------------------------------------------------------------------------------------
    
    static Plane From( float3 p0, float3 p1, float3 p2 )
    {
        Plane plane;
        plane.Normal = normalize( cross( p1 - p0, p2 - p0 ) );
        plane.Distance = dot( plane.Normal, p0 );
        return plane;
    }

    //--------------------------------------------------------------------------------------
    
    // Transformations
    Plane TransformToLocal(float4x3 worldToLocal)
    {
        Plane planeLocal;
        planeLocal.Normal = normalize(mul(float4(Normal, 0.0f), worldToLocal).xyz);
        planeLocal.Distance = dot(planeLocal.Normal, mul(float4(Normal * Distance, 1.0f), worldToLocal).xyz);
        return planeLocal;
    }

    //--------------------------------------------------------------------------------------

    bool PointOutside( float3 p )
    {
        return dot( Normal, p ) - Distance < 0;
    }
    
    // Todo: These all have a rectangle shape when testing with multiple frusta
    // Make them test from nearest point from the far plane and back
    bool SphereOutside( float3 p, float radius )
    {
        return dot( Normal, p ) - Distance < -radius;
    }

    // Checks if the AABB is entirely outside the plane
    bool AABBOutside(float3 aabbMin, float3 aabbMax, float4x3 worldToLocal )
    {
        Plane planeLocal = TransformToLocal(worldToLocal);
        [unroll]
        for (int i = 0; i < 8; i++)
        {
            float3 corner = float3(
                (i & 1) ? aabbMax.x : aabbMin.x,
                (i & 2) ? aabbMax.y : aabbMin.y,
                (i & 4) ? aabbMax.z : aabbMin.z
            );
            
            if (!planeLocal.PointOutside(corner))
                return false; // If any corner is not outside, the AABB is not entirely outside
        }

        return true; // All corners are outside, so the AABB is entirely outside
    }

    bool AABBIntersects( float3 aabbMin, float3 aabbMax, float4x3 worldToLocal )
    {
        Plane planeLocal = TransformToLocal(worldToLocal);

        float3 positiveVertex = (planeLocal.Normal.x >= 0.0 ? aabbMax : aabbMin);
        float3 negativeVertex = (planeLocal.Normal.x >= 0.0 ? aabbMin : aabbMax);

        // Test the positive vertex (farthest in direction of the normal)
        if (dot(planeLocal.Normal, positiveVertex) + planeLocal.Distance < 0.0) {
            // Fully outside this plane
            return -1;
        }

        // Test the negative vertex (closest in direction of the normal)
        if (dot(planeLocal.Normal, negativeVertex) + planeLocal.Distance >= 0.0) {
            // Partially inside or intersects this plane
            return 0;
        }

        // Fully inside this plane
        return 1;
    }

    bool ConeOutside(float3 p, float3 d, float3 up, float h, float outerConeCosine)
    {
        // Calculate the radius of the base of the cone
        float r = h * sqrt( 1.0f - outerConeCosine * outerConeCosine ) / outerConeCosine;

        // Todo: since we check as sphere in point B, if r > h it goes
        float3 a = p;
        float3 b = p + d * h; // Base of the cone

        // Calculate the right vector
        float3 right = cross(d, up);

        // Check top-left, top-right, bottom-right, and bottom-left corners of the base of the cone
        float3 b1 = b + up * r + right * r; // top-right
        float3 b2 = b + up * r - right * r; // top-left
        float3 b3 = b - up * r + right * r; // bottom-right
        float3 b4 = b - up * r - right * r; // bottom-left

        return  PointOutside(a) && 
                PointOutside(b1) && 
                PointOutside(b2) && 
                PointOutside(b3) && 
                PointOutside(b4);
    }

};

//--------------------------------------------------------------------------------------

class Frustum
{
    Plane Planes[6]; // Left, Right, Top, Bottom, Far, Near

    // Calculates a frustum for the given screen tile.
    static Frustum CalculateScreenTiles(uint2 vThreadId, float2 viewDepthMinMax = 1.0f, bool bCullNearPlane = true, float2 invViewportSize = -1 )
    {
        if( invViewportSize.x == -1 )
        {
            invViewportSize = g_vInvViewportSize * CULLING_TILE_SIZE;
        }

        float2 screenSpace[4];
        screenSpace[0] = invViewportSize * float2( vThreadId.xy ); // tl
        screenSpace[1] = invViewportSize * ( float2( vThreadId.x + 1, vThreadId.y ) ); // tr
        screenSpace[2] = invViewportSize * ( float2( vThreadId.x, vThreadId.y + 1 ) ); // bl
        screenSpace[3] = invViewportSize * ( float2( vThreadId.x + 1, vThreadId.y + 1 ) ); // br

        float3 worldSpaceNear[4];
        float3 worldSpaceFar[4];
        for ( int i = 0; i < 4; i++ )
        {
            const float2 uv = float2( screenSpace[i].x, 1.0f - screenSpace[i].y );

            // Far Plane
            const float3 clipFar = float3( uv * 2.0f - float2( 1.0f, 1.0f ), 0.0f ); // 0.0f = far plane in negative depth
            const float4 homPositionFar = mul( g_matProjectionToWorld, float4( clipFar, 1.0f ) );
            worldSpaceFar[i] = g_vCameraPositionWs + ( homPositionFar.xyz / homPositionFar.w );

            // Near Plane
            const float3 clipNear = float3( uv * 2.0f - float2( 1.0f, 1.0f ), 1.0f ); // 1.0f = near plane in positive depth
            const float4 homPositionNear = mul( g_matProjectionToWorld, float4( clipNear, 1.0f ) );
            worldSpaceNear[i] = g_vCameraPositionWs + ( homPositionNear.xyz / homPositionNear.w );

        }

        Frustum frustum;
        frustum.Planes[0] = Plane::From( worldSpaceNear[2], worldSpaceFar[2], worldSpaceFar[0] );
        frustum.Planes[1] = Plane::From( worldSpaceNear[1], worldSpaceFar[1], worldSpaceFar[3] );
        frustum.Planes[2] = Plane::From( worldSpaceNear[0], worldSpaceFar[0], worldSpaceFar[1] );
        frustum.Planes[3] = Plane::From( worldSpaceNear[3], worldSpaceFar[3], worldSpaceFar[2] );

        // Far Plane
        frustum.Planes[4].Normal = -g_vCameraDirWs.xyz;
        frustum.Planes[4].Distance = dot( frustum.Planes[4].Normal, g_vCameraPositionWs + g_vCameraDirWs.xyz * viewDepthMinMax.y );

        // Near Plane
        frustum.Planes[5].Normal = g_vCameraDirWs.xyz;
        frustum.Planes[5].Distance = dot( frustum.Planes[5].Normal, g_vCameraPositionWs + g_vCameraDirWs.xyz * ( viewDepthMinMax.x * bCullNearPlane ) );
        
        return frustum;
    }
    
    //--------------------------------------------------------------------------------------
    
    bool PointInside( float3 p )
    {
        for ( int i = 0; i < 6; i++ )
        {
            if ( Planes[i].PointOutside( p ) )
            {
                return false;
            }
        }

        return true;
    }

    bool SphereInside(float3 p, float radius)
    {
        for (int i = 0; i < 6; i++)
        {
            if (Planes[i].SphereOutside(p, radius))
            {
                return false;
            }
        }
        return true;
    }

    bool ConeInside(float3 p, float3 d, float3 up, float h, float outerConeCosine)
    {
        for (int i = 0; i < 6; i++)
        {
            if ( Planes[i].ConeOutside( p, d, up, h, outerConeCosine ) )
            {
                return false;
            }
        }
        return true;
    }

    bool AABBInside(float3 aabbMin, float3 aabbMax, float4x3 worldtoLocal )
    {
        for (int i = 0; i < 6; i++)
        {
            if (Planes[i].AABBOutside(aabbMin, aabbMax, worldtoLocal))
            {
                return false;
            }
        }
        return true;
    }

    bool AABBInside2(float3 aabbMin, float3 aabbMax, float4x3 worldtoLocal )
    {
        bool fullyInside = true;

        for (int i = 0; i < 6; ++i) {
            int result = Planes[i].AABBIntersects(aabbMin, aabbMax, worldtoLocal);
            
            if (result == -1) {
                // AABB is fully outside of at least one plane
                return false;
            }
            
            if (result == 0) {
                // AABB partially intersects this plane
                fullyInside = false;
            }
        }

        return fullyInside;
    }    
};
