Param(
  [string]$DatasetDir = "D:\DATASET\Signboard",
  [string]$Model = "yolov8n.pt",
  [int]$Epochs = 50,
  [int]$ImgSize = 640,
  [int]$Batch = 8,
  [string]$RunName = "signboard_v1"
)

$ErrorActionPreference = "Stop"

Write-Host "Starting signboard training..."
Write-Host "Dataset: $DatasetDir"

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($null -ne $pythonCmd) {
  & $pythonCmd.Path "C:\Users\Rushil\dev\DrishtiAI\training_yolo\scripts\train_signboard.py" `
    --dataset-dir "$DatasetDir" `
    --model "$Model" `
    --epochs $Epochs `
    --imgsz $ImgSize `
    --batch $Batch `
    --run-name "$RunName"
}
else {
  $pyCmd = Get-Command py -ErrorAction SilentlyContinue
  if ($null -eq $pyCmd) {
    throw "Python was not found. Install Python or run inside an environment where Python is available."
  }
  & $pyCmd.Path -3 "C:\Users\Rushil\dev\DrishtiAI\training_yolo\scripts\train_signboard.py" `
    --dataset-dir "$DatasetDir" `
    --model "$Model" `
    --epochs $Epochs `
    --imgsz $ImgSize `
    --batch $Batch `
    --run-name "$RunName"
}

Write-Host "Training command finished."
