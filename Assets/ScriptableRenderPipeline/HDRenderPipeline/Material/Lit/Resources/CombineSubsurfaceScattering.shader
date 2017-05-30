Shader "Hidden/HDRenderPipeline/CombineSubsurfaceScattering"
{
    Properties
    {
        [HideInInspector] _DstBlend("", Float) = 1 // Can be set to 1 for blending with specular
    }

    SubShader
    {
        Pass
        {
            Stencil
            {
                Ref  1 // StencilBits.SSS
                Comp Equal
                Pass Keep
            }

            Cull   Off
            ZTest  Always
            ZWrite Off
            Blend  One One

            HLSLPROGRAM
            #pragma target 4.5
            #pragma only_renderers d3d11 ps4 metal // TEMP: until we go further in dev
            #pragma enable_d3d11_debug_symbols

            #pragma vertex Vert
            #pragma fragment Frag

            #define SSS_PASS
            #define METERS_TO_MILLIMETERS 1000

            //-------------------------------------------------------------------------------------
            // Include
            //-------------------------------------------------------------------------------------

            #include "../../../../ShaderLibrary/Common.hlsl"
            #include "../../../ShaderConfig.cs.hlsl"
            #include "../../../ShaderVariables.hlsl"
            #define UNITY_MATERIAL_LIT // Needs to be defined before including Material.hlsl
            #include "../../../Material/Material.hlsl"

            //-------------------------------------------------------------------------------------
            // Inputs & outputs
            //-------------------------------------------------------------------------------------

            float _FilterKernelsNearField[SSS_N_PROFILES][SSS_N_SAMPLES_NEAR_FIELD][2]; // 0 = radius, 1 = reciprocal of the PDF
            float _FilterKernelsFarField[SSS_N_PROFILES][SSS_N_SAMPLES_FAR_FIELD][2];   // 0 = radius, 1 = reciprocal of the PDF

            TEXTURE2D(_IrradianceSource);             // Includes transmitted light
            DECLARE_GBUFFER_TEXTURE(_GBufferTexture); // Contains the albedo and SSS parameters

            //-------------------------------------------------------------------------------------
            // Implementation
            //-------------------------------------------------------------------------------------

            // Computes the value of the integrand over a disk: (2 * PI * r) * KernelVal().
            // N.b.: the returned value is multiplied by 4. It is irrelevant due to weight renormalization.
            float3 KernelValCircle(float r, float3 S)
            {
                float3 expOneThird = exp(((-1.0 / 3.0) * r) * S);
                return /* 0.25 * */ S * (expOneThird + expOneThird * expOneThird * expOneThird);
            }

            // Computes F(x)/P(x), s.t. x = sqrt(r^2 + z^2).
            float3 ComputeBilateralWeight(float3 S, float r, float z, float distScale, float rcpPdf)
            {
                // Reducing the integration distance is equivalent to stretching the integration axis.
                float3 valX = KernelValCircle(sqrt(r * r + z * z) * rcp(distScale), S);

                // The reciprocal of the PDF could be reinterpreted as a 'dx' term in Int{F(x)dx}.
                // As we shift the location of the value on the curve during integration,
                // the length of the segment 'dx' under the curve changes approximately linearly.
                float rcpPdfX = rcpPdf * (1 + abs(z) / r);

                return valX * rcpPdfX;
            }

            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_Position;
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
                return output;
            }

            float4 Frag(Varyings input) : SV_Target
            {
                PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw, uint2(0, 0));

                float3 unused;

                BSDFData bsdfData;
                FETCH_GBUFFER(gbuffer, _GBufferTexture, posInput.unPositionSS);
                DECODE_FROM_GBUFFER(gbuffer, 0xFFFFFFFF, bsdfData, unused);

                int    profileID   = bsdfData.subsurfaceProfile;
                float  distScale   = bsdfData.subsurfaceRadius;
                float3 shapeParam  = _ShapeParameters[profileID].rgb;
                float  maxDistance = _ShapeParameters[profileID].a;

                // Reconstruct the view-space position.
                float  rawDepth    = LOAD_TEXTURE2D(_MainDepthTexture, posInput.unPositionSS).r;
                float3 centerPosVS = ComputeViewSpacePosition(posInput.positionSS, rawDepth, _InvProjMatrix);

                // Compute the dimensions of the surface fragment viewed as a quad facing the camera.
                // TODO: this could be done more accurately using a matrix precomputed on the CPU.
                float2 metersPerPixel = float2(ddx_fine(centerPosVS.x), ddy_fine(centerPosVS.y));
                float2 scaledPixPerMm = distScale * rcp(METERS_TO_MILLIMETERS * metersPerPixel);

                // Take the first (central) sample.
                float2 samplePosition   = posInput.unPositionSS;
                float3 sampleIrradiance = LOAD_TEXTURE2D(_IrradianceSource, samplePosition).rgb;

                // We perform point sampling. Therefore, we can avoid the cost
                // of filtering if we stay within the bounds of the current pixel.
                [branch]
                if (maxDistance * max(scaledPixPerMm.x, scaledPixPerMm.y) < 0.5)
                {
                    return float4(bsdfData.diffuseColor * sampleIrradiance, 1);
                }

                bool useNearFieldKernel = true; // TODO

                if (useNearFieldKernel)
                {
                    float  sampleRcpPdf = _FilterKernelsNearField[profileID][0][1];
                    float3 sampleWeight = KernelValCircle(0, shapeParam) * sampleRcpPdf;

                    // Accumulate filtered irradiance and bilateral weights (for renormalization).
                    float3 totalIrradiance = sampleWeight * sampleIrradiance;
                    float3 totalWeight     = sampleWeight;

                    // Perform integration over the screen-aligned plane in the view space.
                    // TODO: it would be more accurate to use the tangent plane in the world space.

                    int validSampleCount = 0;

                    [unroll]
                    for (uint i = 1; i < SSS_N_SAMPLES_NEAR_FIELD; i++)
                    {
                        // Everything except for the radius is a compile-time constant.
                        float  r   = _FilterKernelsNearField[profileID][i][0];
                        float  phi = TWO_PI * VanDerCorputBase2(i);
                        float2 pos = r * float2(cos(phi), sin(phi));

                        samplePosition = posInput.unPositionSS + pos * scaledPixPerMm;
                        sampleRcpPdf   = _FilterKernelsNearField[profileID][i][1];

                        rawDepth         = LOAD_TEXTURE2D(_MainDepthTexture, samplePosition).r;
                        sampleIrradiance = LOAD_TEXTURE2D(_IrradianceSource, samplePosition).rgb;

                        [flatten]
                        if (rawDepth == 0)
                        {
                            // Our sample comes from a region without any geometry.
                            continue;
                        }

                        [flatten]
                        if (any(sampleIrradiance) == false)
                        {
                            // The irradiance is 0. This could happen for 2 reasons.
                            // Most likely, the surface fragment does not have an SSS material.
                            // Alternatively, the surface fragment could be completely shadowed.
                            // Our blur is energy-preserving, so 'sampleWeight' should be set to 0.
                            // We do not terminate the loop since we want to gather the contribution
                            // of the remaining samples (e.g. in case of hair covering skin).
                            continue;
                        }

                        // Apply bilateral weighting.
                        float sampleZ = LinearEyeDepth(rawDepth, _ZBufferParams);
                        float z       = METERS_TO_MILLIMETERS * sampleZ - (METERS_TO_MILLIMETERS * centerPosVS.z);
                        sampleWeight  = ComputeBilateralWeight(shapeParam, r, z, distScale, sampleRcpPdf);

                        totalIrradiance += sampleWeight * sampleIrradiance;
                        totalWeight     += sampleWeight;

                        validSampleCount++;
                    }

                    [branch]
                    if (validSampleCount < SSS_N_SAMPLES_NEAR_FIELD / 2)
                    {
                        // Do not blur.
                        samplePosition   = posInput.unPositionSS;
                        sampleIrradiance = LOAD_TEXTURE2D(_IrradianceSource, samplePosition).rgb;
                        return float4(bsdfData.diffuseColor * sampleIrradiance, 1);
                    }

                    return float4(bsdfData.diffuseColor * totalIrradiance / totalWeight, 1);
                }
                else
                {
                    return float4(0, 0, 0, 1); // TODO
                }
            }
            ENDHLSL
        }
    }
    Fallback Off
}
