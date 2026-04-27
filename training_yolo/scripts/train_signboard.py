#!/usr/bin/env python3
"""
Train a signboard detector from a YOLO-format dataset.

Default dataset path:
    D:\\DATASET\\Signboard

Expected structure:
    Signboard/
      train/
        images/
        labels/
      valid/ or val/
        images/
        labels/
      test/ (optional)
        images/
        labels/
"""

from __future__ import annotations

import argparse
import sys
import torch
from pathlib import Path
from typing import Iterable, List, Optional, Set, Tuple


DEFAULT_DATASET_DIR = Path(r"D:\DATASET\Signboard")
DEFAULT_MODEL = "yolov8n.pt"
DEFAULT_PROJECT_NAME = "signboard_runs"
DEFAULT_RUN_NAME = "signboard_v1"

# Accuracy-oriented defaults for signboard detection.
DEFAULT_EPOCHS = 50
DEFAULT_IMGSZ = 640
DEFAULT_BATCH = 8
DEFAULT_PATIENCE = 15
DEFAULT_WORKERS = 2
# Auto-select GPU (CUDA device 0) when available, otherwise fall back to CPU.
DEFAULT_DEVICE = "0" if torch.cuda.is_available() else "cpu"
DEFAULT_SEED = 42


def _require_dir(path: Path, label: str) -> None:
    if not path.exists() or not path.is_dir():
        raise FileNotFoundError(f"{label} directory not found: {path}")


def _split_dirs(dataset_dir: Path) -> Tuple[Path, Path, Optional[Path]]:
    train_dir = dataset_dir / "train"
    val_dir = dataset_dir / "valid"
    if not val_dir.exists():
        val_dir = dataset_dir / "val"
    test_dir = dataset_dir / "test"
    if not test_dir.exists():
        test_dir = None

    _require_dir(train_dir, "Train")
    _require_dir(val_dir, "Validation")
    if test_dir is not None:
        _require_dir(test_dir, "Test")
    return train_dir, val_dir, test_dir


def _require_yolo_subdirs(split_dir: Path, split_name: str) -> None:
    _require_dir(split_dir / "images", f"{split_name} images")
    _require_dir(split_dir / "labels", f"{split_name} labels")


def _iter_label_files(dirs: Iterable[Path]) -> Iterable[Path]:
    for split_dir in dirs:
        if split_dir is None:
            continue
        labels_dir = split_dir / "labels"
        if labels_dir.exists():
            yield from labels_dir.rglob("*.txt")


def _infer_classes(train_dir: Path, val_dir: Path, test_dir: Optional[Path]) -> List[str]:
    class_ids: Set[int] = set()
    label_files = list(_iter_label_files([train_dir, val_dir, test_dir]))
    if not label_files:
        return ["signboard"]

    for label_path in label_files:
        try:
            text = label_path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            first = line.split()[0]
            try:
                cls_id = int(float(first))
            except ValueError:
                continue
            if cls_id >= 0:
                class_ids.add(cls_id)

    if not class_ids:
        return ["signboard"]

    max_id = max(class_ids)
    if max_id == 0:
        return ["signboard"]
    return [f"class_{i}" for i in range(max_id + 1)]


def _write_data_yaml(
    dataset_dir: Path,
    train_dir: Path,
    val_dir: Path,
    test_dir: Optional[Path],
    class_names: List[str],
) -> Path:
    yaml_path = dataset_dir / "signboard_data.yaml"
    root_rel = dataset_dir.resolve().as_posix()

    lines = [
        f"path: {root_rel}",
        f"train: {train_dir.name}/images",
        f"val: {val_dir.name}/images",
    ]
    if test_dir is not None:
        lines.append(f"test: {test_dir.name}/images")
    lines.append("names:")
    for idx, name in enumerate(class_names):
        safe_name = name.replace("'", "")
        lines.append(f"  {idx}: '{safe_name}'")

    yaml_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return yaml_path


def _print_plan(
    dataset_dir: Path,
    data_yaml: Path,
    model: str,
    project_dir: Path,
    run_name: str,
    class_names: List[str],
    epochs: int,
    imgsz: int,
    batch: int,
) -> None:
    print("\n=== Signboard Training Plan ===")
    print(f"Dataset      : {dataset_dir}")
    print(f"data.yaml    : {data_yaml}")
    print(f"Base model   : {model}")
    print(f"Project dir  : {project_dir}")
    print(f"Run name     : {run_name}")
    print(f"Classes      : {class_names}")
    print(f"Epochs       : {epochs}")
    print(f"Image size   : {imgsz}")
    print(f"Batch        : {batch}")
    print("================================\n")


def _make_epoch_callback(total_epochs: int):
    """Return an Ultralytics callback that prints a concise per-epoch summary."""

    def on_train_epoch_end(trainer) -> None:
        epoch = trainer.epoch + 1  # 0-indexed internally
        metrics = trainer.label_loss_items(trainer.tloss, prefix="train") or {}
        loss_str = "  ".join(
            f"{k}: {v:.4f}" for k, v in metrics.items()
        ) if metrics else f"loss: {float(trainer.tloss):.4f}"
        lr = trainer.optimizer.param_groups[0].get("lr", 0)
        print(
            f"[Epoch {epoch:>4}/{total_epochs}]  {loss_str}  lr: {lr:.6f}",
            flush=True,
        )

    def on_val_end(validator) -> None:
        # Print mAP after each validation pass
        try:
            metrics = validator.metrics
            map50 = getattr(metrics, 'map50', None)
            map50_95 = getattr(metrics, 'map', None)
            if map50 is not None:
                print(
                    f"  [Val]  mAP@50: {map50:.4f}  mAP@50-95: {map50_95:.4f}",
                    flush=True,
                )
        except Exception:
            pass

    return on_train_epoch_end, on_val_end


def main() -> int:
    parser = argparse.ArgumentParser(description="Train signboard YOLO model.")
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--model", type=str, default=DEFAULT_MODEL)
    parser.add_argument("--project-dir", type=Path, default=Path("training_yolo") / DEFAULT_PROJECT_NAME)
    parser.add_argument("--run-name", type=str, default=DEFAULT_RUN_NAME)
    parser.add_argument("--epochs", type=int, default=DEFAULT_EPOCHS)
    parser.add_argument("--imgsz", type=int, default=DEFAULT_IMGSZ)
    parser.add_argument("--batch", type=int, default=DEFAULT_BATCH)
    parser.add_argument("--patience", type=int, default=DEFAULT_PATIENCE)
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--device", type=str, default=DEFAULT_DEVICE,
                        help="Training device: 'cpu', '0', '0,1', etc. Auto-detected if not set.")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--no-export", action="store_true", help="Skip ONNX export.")
    args = parser.parse_args()

    dataset_dir = args.dataset_dir.resolve()
    project_dir = args.project_dir.resolve()

    try:
        train_dir, val_dir, test_dir = _split_dirs(dataset_dir)
        _require_yolo_subdirs(train_dir, "Train")
        _require_yolo_subdirs(val_dir, "Validation")
        if test_dir is not None:
            _require_yolo_subdirs(test_dir, "Test")
    except FileNotFoundError as exc:
        print(f"[ERROR] {exc}")
        return 1

    class_names = _infer_classes(train_dir, val_dir, test_dir)
    data_yaml = _write_data_yaml(dataset_dir, train_dir, val_dir, test_dir, class_names)

    _print_plan(
        dataset_dir=dataset_dir,
        data_yaml=data_yaml,
        model=args.model,
        project_dir=project_dir,
        run_name=args.run_name,
        class_names=class_names,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
    )

    try:
        from ultralytics import YOLO
    except Exception as exc:
        print("[ERROR] ultralytics is not installed or failed to import.")
        print("Install with: pip install ultralytics")
        print(f"Details: {exc}")
        return 1

    project_dir.mkdir(parents=True, exist_ok=True)
    model = YOLO(args.model)

    # Register per-epoch progress callbacks
    on_epoch_end, on_val_end = _make_epoch_callback(args.epochs)
    model.add_callback("on_train_epoch_end", on_epoch_end)
    model.add_callback("on_val_end", on_val_end)

    device_label = args.device if args.device != "cpu" else "CPU (no CUDA detected)"
    print(f"[INFO] Starting training on device: {device_label}")
    print(f"[INFO] Epochs: {args.epochs}  |  ImgSz: {args.imgsz}  |  Batch: {args.batch}")
    print("-" * 60)
    # AMP and cache are GPU features; disable them on CPU to avoid errors/slowdowns
    use_gpu = args.device != "cpu"
    model.train(
        data=str(data_yaml),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        patience=args.patience,
        workers=args.workers,
        device=args.device,
        project=str(project_dir),
        name=args.run_name,
        seed=args.seed,
        cos_lr=True,
        close_mosaic=10,
        cache=use_gpu,
        amp=use_gpu,
        pretrained=True,
        verbose=True,
    )

    best_weights = project_dir / args.run_name / "weights" / "best.pt"
    if not best_weights.exists():
        print(f"[WARN] best.pt not found at expected path: {best_weights}")
        print("[INFO] Training finished, but export/validation steps were skipped.")
        return 0

    print("[INFO] Running validation on best weights...")
    best_model = YOLO(str(best_weights))
    best_model.val(data=str(data_yaml), imgsz=args.imgsz, device=args.device, verbose=True)

    if not args.no_export:
        print("[INFO] Exporting ONNX...")
        best_model.export(
            format="onnx",
            imgsz=args.imgsz,
            opset=12,
            simplify=True,
            dynamic=False,
        )

    print("[DONE] Training pipeline completed.")
    print(f"[DONE] Best weights: {best_weights}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
