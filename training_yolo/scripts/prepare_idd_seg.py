#!/usr/bin/env python3
import argparse
import os
import random
from pathlib import Path

import cv2
import numpy as np
from PIL import Image


def list_image_ids(image_dir: Path):
    files = sorted([p for p in image_dir.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg"}])
    ids = []
    for p in files:
        name = p.stem
        # Expect Image_XXXX
        if name.lower().startswith("image_"):
            ids.append(name.split("_", 1)[1])
    return sorted(set(ids), key=lambda x: int(x) if x.isdigit() else x)


def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)


def mask_to_polygons(mask: np.ndarray, min_area: float, epsilon: float):
    # mask is binary 0/1
    mask_u8 = (mask > 0).astype("uint8") * 255
    contours, _ = cv2.findContours(mask_u8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    polys = []
    for cnt in contours:
        area = cv2.contourArea(cnt)
        if area < min_area:
            continue
        if epsilon > 0:
            cnt = cv2.approxPolyDP(cnt, epsilon, True)
        if cnt is None or len(cnt) < 3:
            continue
        cnt = cnt.reshape(-1, 2)
        polys.append(cnt)
    return polys


def write_yolo_seg_label(label_path: Path, polys, w: int, h: int, class_id: int):
    lines = []
    for poly in polys:
        # Normalize
        coords = []
        for x, y in poly:
            coords.append(f"{x / w:.6f}")
            coords.append(f"{y / h:.6f}")
        if len(coords) < 6:
            continue
        lines.append(f"{class_id} " + " ".join(coords))
    label_path.write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw_dir", type=str, required=True, help="Path to IDD_RESIZED")
    ap.add_argument("--out_dir", type=str, required=True, help="Output dataset root")
    ap.add_argument("--val_ratio", type=float, default=0.1)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--min_area", type=float, default=50.0)
    ap.add_argument("--epsilon", type=float, default=1.0, help="Polygon simplification epsilon (pixels)")
    ap.add_argument("--class_name", type=str, default="foreground")
    args = ap.parse_args()

    raw_dir = Path(args.raw_dir)
    image_dir = raw_dir / "image_archive"
    mask_dir = raw_dir / "mask_archive"

    if not image_dir.exists() or not mask_dir.exists():
        raise SystemExit("Expected image_archive and mask_archive inside raw_dir.")

    out_dir = Path(args.out_dir)
    images_train = out_dir / "images" / "train"
    images_val = out_dir / "images" / "val"
    labels_train = out_dir / "labels" / "train"
    labels_val = out_dir / "labels" / "val"
    for p in [images_train, images_val, labels_train, labels_val]:
        ensure_dir(p)

    ids = list_image_ids(image_dir)
    if not ids:
        raise SystemExit("No Image_*.png files found in image_archive.")

    random.seed(args.seed)
    random.shuffle(ids)
    val_count = int(len(ids) * args.val_ratio)
    val_ids = set(ids[:val_count])

    converted = 0
    for _id in ids:
        img_path = image_dir / f"Image_{_id}.png"
        if not img_path.exists():
            img_path = image_dir / f"Image_{_id}.jpg"
        mask_path = mask_dir / f"Mask_{_id}.png"
        if not img_path.exists() or not mask_path.exists():
            continue

        split = "val" if _id in val_ids else "train"
        dst_img = (images_val if split == "val" else images_train) / img_path.name
        dst_lbl = (labels_val if split == "val" else labels_train) / (img_path.stem + ".txt")

        # Copy image
        if not dst_img.exists():
            dst_img.write_bytes(img_path.read_bytes())

        # Load mask + image size
        mask = np.array(Image.open(mask_path).convert("L"))
        h, w = mask.shape[:2]

        polys = mask_to_polygons(mask, min_area=args.min_area, epsilon=args.epsilon)
        write_yolo_seg_label(dst_lbl, polys, w, h, class_id=0)
        converted += 1

    # Write data.yaml
    data_yaml = out_dir / "data.yaml"
    data_yaml.write_text(
        "\n".join(
            [
                f"path: {out_dir.as_posix()}",
                "train: images/train",
                "val: images/val",
                "nc: 1",
                f"names: ['{args.class_name}']",
            ]
        )
        + "\n"
    )

    print(f"Prepared dataset at: {out_dir}")
    print(f"Images converted: {converted}")
    print(f"Val split: {len(val_ids)} / {len(ids)}")


if __name__ == "__main__":
    main()
