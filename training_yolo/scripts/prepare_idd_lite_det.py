#!/usr/bin/env python3
import argparse
from pathlib import Path

import cv2
import numpy as np


IDD_LITE_NAMES = [
    "drivable",
    "non_drivable",
    "living",
    "vehicle",
    "roadside",
    "far",
    "sky",
]


def ensure_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)


def iter_images(root: Path):
    for ext in ("*.jpg", "*.jpeg", "*.png"):
        for p in root.rglob(ext):
            yield p


def label_path_for_image(img_path: Path, img_root: Path, label_root: Path):
    rel = img_path.relative_to(img_root)
    # Replace leftImg8bit -> gtFine and _image -> _label
    label_name = img_path.stem.replace("_image", "_label") + ".png"
    return label_root / rel.parent / label_name


def mask_to_bboxes(mask: np.ndarray, class_id: int, min_area: int):
    class_mask = (mask == class_id).astype("uint8")
    if class_mask.sum() == 0:
        return []
    contours, _ = cv2.findContours(class_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    boxes = []
    for cnt in contours:
        x, y, w, h = cv2.boundingRect(cnt)
        if w * h < min_area:
            continue
        boxes.append((x, y, w, h))
    return boxes


def convert_split(img_root: Path, label_root: Path, out_root: Path, split: str, min_area: int):
    images_out = out_root / "images" / split
    labels_out = out_root / "labels" / split
    ensure_dir(images_out)
    ensure_dir(labels_out)

    total_images = 0
    total_labels = 0
    for img_path in iter_images(img_root / split):
        label_path = label_path_for_image(img_path, img_root, label_root)
        if not label_path.exists():
            continue
        mask = cv2.imread(str(label_path), cv2.IMREAD_UNCHANGED)
        if mask is None:
            continue

        h, w = mask.shape[:2]
        yolo_lines = []
        for class_id in range(len(IDD_LITE_NAMES)):
            for x, y, bw, bh in mask_to_bboxes(mask, class_id, min_area):
                x_center = (x + bw / 2) / w
                y_center = (y + bh / 2) / h
                bw_norm = bw / w
                bh_norm = bh / h
                yolo_lines.append(
                    f"{class_id} {x_center:.6f} {y_center:.6f} {bw_norm:.6f} {bh_norm:.6f}"
                )

        # Copy image
        dst_img = images_out / img_path.name
        if not dst_img.exists():
            dst_img.write_bytes(img_path.read_bytes())
        # Write labels (can be empty)
        dst_lbl = labels_out / (img_path.stem + ".txt")
        dst_lbl.write_text("\n".join(yolo_lines))

        total_images += 1
        total_labels += len(yolo_lines)

    return total_images, total_labels


def write_data_yaml(out_root: Path):
    data_yaml = out_root / "data.yaml"
    names_list = ", ".join([f"'{n}'" for n in IDD_LITE_NAMES])
    data_yaml.write_text(
        "\n".join(
            [
                f"path: {out_root.as_posix()}",
                "train: images/train",
                "val: images/val",
                f"nc: {len(IDD_LITE_NAMES)}",
                f"names: [{names_list}]",
            ]
        )
        + "\n"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw_dir", required=True, help="Path to idd20k_lite")
    ap.add_argument("--out_dir", required=True, help="Output dataset root")
    ap.add_argument("--min_area", type=int, default=150, help="Minimum bbox area in pixels")
    args = ap.parse_args()

    raw_dir = Path(args.raw_dir)
    img_root = raw_dir / "leftImg8bit"
    label_root = raw_dir / "gtFine"
    if not img_root.exists() or not label_root.exists():
        raise SystemExit("Expected leftImg8bit and gtFine inside raw_dir.")

    out_root = Path(args.out_dir)
    ensure_dir(out_root)

    train_count, train_labels = convert_split(img_root, label_root, out_root, "train", args.min_area)
    val_count, val_labels = convert_split(img_root, label_root, out_root, "val", args.min_area)
    write_data_yaml(out_root)

    print(f"Prepared IDD-lite detection dataset at: {out_root}")
    print(f"Train images: {train_count}, labels: {train_labels}")
    print(f"Val images: {val_count}, labels: {val_labels}")


if __name__ == "__main__":
    main()
