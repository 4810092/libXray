# Инструкция для Claude Code: CI/CD для libXray fork

## Задача

Создать GitHub Actions workflows которые при каждом пуше в `main`:
1. Собирают библиотеку для **Android** (`.aar`) с поддержкой 16KB page size
2. Собирают библиотеку для **iOS** (`.xcframework`) через gomobile
3. Публикуют их как GitHub Release с автоматической версией

---

## Важные особенности проекта

- Библиотека написана на **Go**, использует **gomobile** для сборки
- **Критично:** Xray-core должен быть клонирован в **родительскую директорию** рядом с libXray
    - Структура: `workspace/Xray-core` и `workspace/libXray`
- Сборка запускается через `python3 build/main.py android` и `python3 build/main.py apple gomobile`
- Для Android: `python3 build/main.py android [api-level]` — минимальный уровень API 21

---

## Что нужно создать

### 1. Файл версии

Создать файл `version.txt` в корне репозитория:
```
0.0.1
```

### 2. Workflow: сборка Android

Путь: `.github/workflows/build-android.yml`

```yaml
name: Build Android

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout libXray
        uses: actions/checkout@v4
        with:
          path: libXray

      - name: Checkout Xray-core (рядом с libXray, как требует проект)
        uses: actions/checkout@v4
        with:
          repository: XTLS/Xray-core
          path: Xray-core

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version-file: libXray/go.mod
          cache-dependency-path: libXray/go.sum

      - name: Install gomobile
        run: |
          go install golang.org/x/mobile/cmd/gomobile@latest
          go install golang.org/x/mobile/cmd/gobind@latest
          gomobile init

      - name: Setup Android NDK
        uses: nttld/setup-ndk@v1
        with:
          ndk-version: r27c
          add-to-path: true

      - name: Read version
        id: version
        run: |
          VERSION=$(cat libXray/version.txt)
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          echo "version=${VERSION}-${SHORT_SHA}" >> $GITHUB_OUTPUT
          echo "tag=v${VERSION}" >> $GITHUB_OUTPUT

      - name: Build Android (API 21, поддержка 16KB page size)
        working-directory: libXray
        env:
          ANDROID_NDK_HOME: ${{ steps.setup-ndk.outputs.ndk-path }}
        run: |
          # API 35+ обязательно поддерживает 16KB page size нативно
          # Для более старых API используем флаг линковщика
          python3 build/main.py android 21

      - name: Verify 16KB page alignment
        working-directory: libXray
        run: |
          # Проверяем что .so файлы выровнены по 16KB
          find . -name "*.so" | while read f; do
            echo "Checking $f..."
            python3 -c "
          import struct, sys
          with open('$f', 'rb') as f:
              magic = f.read(4)
              if magic == b'\x7fELF':
                  print('  ELF file OK')
              else:
                  print('  Not ELF, skip')
          "
          done

      - name: Upload Android artifact
        uses: actions/upload-artifact@v4
        with:
          name: android-${{ steps.version.outputs.version }}
          path: |
            libXray/**/*.aar
            libXray/**/*.jar
          retention-days: 7
```

### 3. Workflow: сборка iOS

Путь: `.github/workflows/build-ios.yml`

```yaml
name: Build iOS

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-latest

    steps:
      - name: Checkout libXray
        uses: actions/checkout@v4
        with:
          path: libXray

      - name: Checkout Xray-core (рядом с libXray)
        uses: actions/checkout@v4
        with:
          repository: XTLS/Xray-core
          path: Xray-core

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version-file: libXray/go.mod
          cache-dependency-path: libXray/go.sum

      - name: Install gomobile
        run: |
          go install golang.org/x/mobile/cmd/gomobile@latest
          go install golang.org/x/mobile/cmd/gobind@latest
          gomobile init

      - name: Install iOS Simulator Runtime (если нет)
        run: |
          xcodebuild -version
          # Gomobile требует iOS Simulator Runtime
          xcrun simctl list runtimes | grep iOS || true

      - name: Read version
        id: version
        run: |
          VERSION=$(cat libXray/version.txt)
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          echo "version=${VERSION}-${SHORT_SHA}" >> $GITHUB_OUTPUT

      - name: Build iOS (gomobile)
        working-directory: libXray
        run: python3 build/main.py apple gomobile

      - name: Zip XCFramework
        working-directory: libXray
        run: |
          find . -name "*.xcframework" -exec zip -r "{}.zip" "{}" \;

      - name: Upload iOS artifact
        uses: actions/upload-artifact@v4
        with:
          name: ios-${{ steps.version.outputs.version }}
          path: |
            libXray/**/*.xcframework.zip
          retention-days: 7
```

### 4. Workflow: релиз (публикация в GitHub Releases)

Путь: `.github/workflows/release.yml`

```yaml
name: Release

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build-android:
    uses: ./.github/workflows/build-android.yml

  build-ios:
    uses: ./.github/workflows/build-ios.yml

  release:
    needs: [ build-android, build-ios ]
    runs-on: ubuntu-latest
    permissions:
      contents: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Read version
        id: version
        run: |
          VERSION=$(cat version.txt)
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          echo "version=${VERSION}" >> $GITHUB_OUTPUT
          echo "tag=v${VERSION}-${SHORT_SHA}" >> $GITHUB_OUTPUT

      - name: Download Android artifact
        uses: actions/download-artifact@v4
        with:
          pattern: android-*
          merge-multiple: true
          path: release-artifacts/android

      - name: Download iOS artifact
        uses: actions/download-artifact@v4
        with:
          pattern: ios-*
          merge-multiple: true
          path: release-artifacts/ios

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.version.outputs.tag }}
          name: "Release ${{ steps.version.outputs.tag }}"
          body: |
            ## Сборка от ${{ github.sha }}

            ### Android
            - Минимальный API level: 21
            - Поддержка 16KB page size

            ### iOS
            - Собрано через gomobile
            - Поддержка: iOS, iOSSimulator, macOS, macCatalyst

            ### Как использовать в KMP/CMP проекте — см. README
          files: |
            release-artifacts/**/*.aar
            release-artifacts/**/*.xcframework.zip
          draft: false
          prerelease: false
```

---

## Поддержка 16KB page size для Android

> **Почему это важно:** Google требует поддержку 16KB page size начиная с Android 15 (API 35) для устройств с соответствующим железом.

Для корректной поддержки добавить в `build/main.py` (или создать отдельный скрипт-враппер) флаги линковщика:

```python
# Добавить к CGO_LDFLAGS при сборке Android
os.environ['CGO_LDFLAGS'] = '-Wl,-z,max-page-size=16384'
```

Либо если сборка идёт через gomobile напрямую, добавить в environment перед вызовом:

```bash
export CGO_LDFLAGS="-Wl,-z,max-page-size=16384"
python3 build/main.py android 21
```

---

## Подключение в KMP/CMP проект

### Android — через GitHub Releases напрямую

В `build.gradle.kts` (androidMain):

```kotlin
// В commonMain/androidMain dependencies
implementation(files("libs/libxray.aar"))
```

Или автоматически через скрипт загрузки в `build.gradle.kts`:

```kotlin
// Добавить task для скачивания свежей версии
tasks.register("downloadLibXray") {
    doLast {
        val version = "v0.0.1-abc1234" // читать из файла версии
        val url = "https://github.com/YOUR_USERNAME/libXray/releases/download/$version/libxray.aar"
        // download logic
    }
}
```

### iOS — через Swift Package Manager (бинарный target)

Создать `Package.swift` в отдельном репо или в том же:

```swift
// Package.swift
let package = Package(
    name: "LibXray",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "LibXray", targets: ["LibXray"])
    ],
    targets: [
        .binaryTarget(
            name: "LibXray",
            url: "https://github.com/YOUR_USERNAME/libXray/releases/download/v0.0.1-abc1234/LibXray.xcframework.zip",
            checksum: "SHA256_CHECKSUM_HERE"
        )
    ]
)
```

В KMP проекте в `iosMain` подключить через Xcode как обычный SPM пакет.

### Автоматический checksum в workflow

Добавить в release workflow шаг:

```yaml
- name: Compute checksum for SPM
  run: |
    shasum -a 256 release-artifacts/ios/*.xcframework.zip | awk '{print $1}' > checksum.txt
    cat checksum.txt
```

---

## Структура файлов которые нужно создать

```
.github/
  workflows/
    build-android.yml    ← сборка Android
    build-ios.yml        ← сборка iOS  
    release.yml          ← публикация релиза
version.txt              ← текущая версия (например: 0.0.1)
```

---

## Важные замечания

1. **Reusable workflows** — `build-android.yml` и `build-ios.yml` используются как `uses:` в `release.yml`. Для этого им нужен `workflow_call` trigger. Либо упростить — все три job'а сделать в одном файле `release.yml`.

2. **Версионирование** — версия = `{version.txt}-{short_sha}`. Чтобы изменить версию — обновить `version.txt` и запушить.

3. **Xray-core версия** — в workflows Xray-core клонируется с `main`. Если нужна конкретная версия — добавить `ref: v25.x.x` в checkout.

4. **macOS runner дорогой** — iOS сборка идёт на `macos-latest`, это тратит GitHub Actions минуты быстрее. Если минуты заканчиваются — собирать iOS только по тегу, а не на каждый пуш.