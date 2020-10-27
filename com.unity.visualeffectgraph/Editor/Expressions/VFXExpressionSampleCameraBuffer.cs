using System;
using System.Linq;
using System.Runtime.CompilerServices;
using UnityEngine;
using UnityEngine.VFX;

namespace UnityEditor.VFX
{
    class VFXExpressionSampleCameraBuffer : VFXExpression
    {
        public VFXExpressionSampleCameraBuffer() : this(VFXCameraBufferValue.Default, VFXValue<Vector2>.Default)
        {
        }

        public VFXExpressionSampleCameraBuffer(VFXExpression cameraBuffer, VFXExpression uv)
            : base(Flags.InvalidOnCPU, new VFXExpression[2] { cameraBuffer, uv })
        {}

        sealed public override VFXExpressionOperation operation { get { return VFXExpressionOperation.None; } }
        sealed public override VFXValueType valueType { get { return VFXValueType.Float4; } }

        public sealed override string GetCodeString(string[] parents)
        {
            return string.Format("SAMPLE_TEXTURE2D_X_LOD({0}, sampler{0}, {1}, 0)", parents[0], parents[1]);
        }
    }
}
