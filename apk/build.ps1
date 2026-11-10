$ErrorActionPreference = 'Stop'
$root = "C:\Users\TI\Documents\Trae-CN\temp_20261110_01"
$BT   = "$root\sdk\bt\android-14"
$JAR  = "$root\sdk\plat\android-34\android.jar"
$SRC  = "$root\apk"
$OUT  = "$root\apk\build"

if (Test-Path $OUT) { Remove-Item $OUT -Recurse -Force }
New-Item -ItemType Directory -Force $OUT, "$OUT\gen", "$OUT\classes", "$OUT\dex" | Out-Null

Push-Location $SRC
try {
  Write-Host "== aapt2 compile =="
  & "$BT\aapt2.exe" compile --dir res -o "$OUT\res.zip"
  if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }

  Write-Host "== aapt2 link =="
  & "$BT\aapt2.exe" link -o "$OUT\base.apk" -I $JAR --manifest AndroidManifest.xml `
      -R "$OUT\res.zip" --java "$OUT\gen" --min-sdk-version 26 --target-sdk-version 34
  if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

  Write-Host "== javac =="
  $files = @(Get-ChildItem -Recurse -Filter *.java "$SRC\src", "$OUT\gen" | ForEach-Object { $_.FullName })
  & javac -source 8 -target 8 -nowarn -bootclasspath $JAR -cp $JAR -d "$OUT\classes" $files
  if ($LASTEXITCODE -ne 0) { throw "javac failed" }

  Write-Host "== d8 =="
  $cls = @(Get-ChildItem -Recurse -Filter *.class "$OUT\classes" | ForEach-Object { $_.FullName })
  & "$BT\d8.bat" --lib $JAR --min-api 26 --output "$OUT\dex" $cls
  if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

  Write-Host "== merge dex =="
  & jar uf "$OUT\base.apk" -C "$OUT\dex" classes.dex
  if ($LASTEXITCODE -ne 0) { throw "jar merge failed" }

  Write-Host "== zipalign =="
  & "$BT\zipalign.exe" -f 4 "$OUT\base.apk" "$OUT\aligned.apk"
  if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

  if (-not (Test-Path "$SRC\nb.keystore")) {
    Write-Host "== keytool =="
    & keytool -genkeypair -keystore "$SRC\nb.keystore" -alias nb -storepass netbatt `
        -keypass netbatt -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=NetBatt, O=NetBatt" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
  }

  Write-Host "== apksigner =="
  & "$BT\apksigner.bat" sign --ks "$SRC\nb.keystore" --ks-pass pass:netbatt --key-pass pass:netbatt `
      --out "$OUT\NetBattConsole.apk" "$OUT\aligned.apk"
  if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

  & "$BT\apksigner.bat" verify --print-certs "$OUT\NetBattConsole.apk" | Select-Object -First 3
  Write-Host "== OK =="
  Get-Item "$OUT\NetBattConsole.apk" | Select-Object FullName, Length
}
finally {
  Pop-Location
}
