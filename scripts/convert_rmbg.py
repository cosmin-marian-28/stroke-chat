#!/usr/bin/env python3
"""
Download RMBG-1.4 and convert to CoreML for iOS.

Usage:
  python3 -m pip install torch torchvision coremltools safetensors huggingface_hub pillow
  python3 scripts/convert_rmbg.py

Output: ios/Runner/RMBG2.mlpackage (add to Xcode project)
"""

import os
import sys
import torch
import torch.nn as nn
import numpy as np

MODEL_ID = "briaai/RMBG-1.4"
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "ios", "Runner")
INPUT_SIZE = 1024


class RMBGWrapper(nn.Module):
    """Wraps RMBG to return only the final sigmoid mask."""
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        outputs = self.model(x)
        # outputs is (list_of_masks, list_of_features)
        # First mask at index 0 is the final full-res mask
        mask = torch.sigmoid(outputs[0][0])
        return mask


def main():
    from huggingface_hub import snapshot_download
    from safetensors.torch import load_file
    import importlib.util
    import coremltools as ct

    print(f"Downloading {MODEL_ID}...")
    model_dir = snapshot_download(MODEL_ID)

    # Patch sys.path so the model files can import each other
    sys.path.insert(0, model_dir)

    # Patch the relative import in briarmbg.py
    briarmbg_path = os.path.join(model_dir, "briarmbg.py")
    with open(briarmbg_path, "r") as f:
        src = f.read()
    src = src.replace("from .MyConfig import RMBGConfig", "from MyConfig import RMBGConfig")

    patched_path = os.path.join(model_dir, "_briarmbg_patched.py")
    with open(patched_path, "w") as f:
        f.write(src)

    spec = importlib.util.spec_from_file_location("briarmbg", patched_path)
    briarmbg = importlib.util.module_from_spec(spec)
    sys.modules["briarmbg"] = briarmbg
    spec.loader.exec_module(briarmbg)

    # Load model weights
    model = briarmbg.BriaRMBG()
    weights_path = os.path.join(model_dir, "model.safetensors")
    if os.path.exists(weights_path):
        state_dict = load_file(weights_path)
    else:
        weights_path = os.path.join(model_dir, "pytorch_model.bin")
        state_dict = torch.load(weights_path, map_location="cpu")
    model.load_state_dict(state_dict)
    model.eval()

    # Wrap to return single output
    wrapped = RMBGWrapper(model)
    wrapped.eval()

    print("Tracing model...")
    dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, dummy)

    print("Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                scale=1.0 / 255.0,
                bias=[0, 0, 0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="mask")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )

    out_path = os.path.join(OUTPUT_DIR, "RMBG2.mlpackage")
    mlmodel.save(out_path)
    size_mb = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fns in os.walk(out_path)
        for f in fns
    ) / (1024 * 1024)
    print(f"\nSaved to: {out_path} ({size_mb:.1f} MB)")
    print("Now add RMBG2.mlpackage to your Xcode project (drag into Runner target).")
    print("Make sure 'Target Membership' is checked for Runner.")


if __name__ == "__main__":
    main()
