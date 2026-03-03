import io
import torch
import numpy as np
from PIL import Image
from fastapi import FastAPI, UploadFile, File
from fastapi.responses import Response
from transformers import AutoModelForImageSegmentation
from torchvision import transforms

app = FastAPI()

# Load RMBG-2.0 once at startup
device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"Loading RMBG-1.4 on {device}...")
model = AutoModelForImageSegmentation.from_pretrained(
    "briaai/RMBG-1.4", trust_remote_code=True
)
model.to(device)
model.eval()
print("RMBG-1.4 ready")

transform = transforms.Compose([
    transforms.Resize((1024, 1024)),
    transforms.ToTensor(),
    transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
])


def remove_bg(image: Image.Image) -> Image.Image:
    orig_w, orig_h = image.size
    input_tensor = transform(image).unsqueeze(0).to(device)

    with torch.no_grad():
        result = model(input_tensor)

    # RMBG-1.4 returns a list of lists — get the final prediction
    if isinstance(result, (list, tuple)):
        pred = result[0]
        if isinstance(pred, (list, tuple)):
            pred = pred[0]
    else:
        pred = result

    mask = torch.sigmoid(pred).squeeze().cpu()
    mask_pil = transforms.ToPILImage()(mask)
    mask_pil = mask_pil.resize((orig_w, orig_h), Image.BILINEAR)

    # Apply mask as alpha channel
    image = image.convert("RGBA")
    r, g, b, _ = image.split()
    result = Image.merge("RGBA", (r, g, b, mask_pil))
    return result


@app.post("/remove-bg")
async def remove_bg_endpoint(file: UploadFile = File(...)):
    data = await file.read()
    image = Image.open(io.BytesIO(data)).convert("RGB")
    result = remove_bg(image)

    buf = io.BytesIO()
    result.save(buf, format="PNG")
    buf.seek(0)
    return Response(content=buf.getvalue(), media_type="image/png")


@app.post("/remove-bg-batch")
async def remove_bg_batch_endpoint(files: list[UploadFile] = File(...)):
    """Process multiple frames, return as multipart."""
    import struct

    results = []
    for f in files:
        data = await f.read()
        image = Image.open(io.BytesIO(data)).convert("RGB")
        result = remove_bg(image)
        buf = io.BytesIO()
        result.save(buf, format="PNG")
        results.append(buf.getvalue())

    # Pack as: [4-byte length][png bytes] repeated
    output = io.BytesIO()
    for png_bytes in results:
        output.write(struct.pack("<I", len(png_bytes)))
        output.write(png_bytes)

    output.seek(0)
    return Response(content=output.getvalue(), media_type="application/octet-stream")
