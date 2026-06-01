# Подписание iOS-сборок в GitHub Actions

Этот документ описывает подход, который сейчас используется в
`.github/workflows/testflight-sync.yml` для сборки и загрузки iOS-архива в
TestFlight. Его можно использовать как шаблон для других Xcode-проектов, где
нужно собирать и подписывать приложение в CI без коммита приватных signing
assets.

## Текущая модель

Workflow разделяет публичную конфигурацию проекта и приватные данные
подписания:

- публичные Xcode-настройки остаются в репозитории;
- bundle identifiers и Apple Developer Team ID приходят через GitHub Actions
  variables;
- App Store Connect API key и опциональные локальные signing assets приходят
  через GitHub Actions secrets;
- сгенерированный локальный `.xcconfig`, сертификаты, provisioning profiles и
  временный keychain существуют только на runner.

Основной путь подписания - Xcode-managed signing через App Store Connect API.
Workflow передает `xcodebuild` флаги `-allowProvisioningUpdates` и
`-authenticationKey*`, чтобы Xcode мог сам найти или обновить provisioning во
время archive/export.

Дополнительный путь нужен для проектов, которым недостаточно managed signing:
перед архивированием job импортирует `.p12` certificate и provisioning profiles
из secrets. Этот путь включается только при
`ENABLE_LOCAL_SIGNING_ASSETS=true`.

## Конфигурация GitHub

Variables репозитория или environment:

- `OVERLAY_BASE_PACKAGE_IDENTIFIER`: базовый bundle identifier для приложения и
  extensions.
- `OVERLAY_DEVELOPMENT_TEAM`: Apple Developer Team ID.
- `ENABLE_LOCAL_SIGNING_ASSETS`: `true`, если job должен импортировать
  certificate/profile archive из secrets.
- `OVERLAY_MACOS_SYSTEM_PROFILE_SPECIFIER` и
  `OVERLAY_MACOS_STANDALONE_PROFILE_SPECIFIER`: macOS-only значения для того же
  workflow; для iOS-архива `SFI` не обязательны.

Secrets репозитория или environment:

- `ASC_KEY_ID`: App Store Connect API key ID.
- `ASC_KEY_ISSUER_ID`: App Store Connect issuer ID.
- `ASC_KEY_P8`: содержимое приватного `.p8` ключа App Store Connect.
- `BUILD_CERTIFICATE_BASE64`: опциональный base64-encoded `.p12` signing
  certificate.
- `P12_PASSWORD`: пароль от `BUILD_CERTIFICATE_BASE64`.
- `KEYCHAIN_PASSWORD`: пароль временного CI keychain.
- `APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64`: опциональный base64-encoded
  `tar.gz` с `.mobileprovision` и/или `.provisionprofile` файлами.

Для текущего iOS flow обязательны только `ASC_*` secrets и две overlay
variables: `OVERLAY_BASE_PACKAGE_IDENTIFIER` и `OVERLAY_DEVELOPMENT_TEAM`.
Certificate/profile secrets нужны только там, где нельзя полностью положиться
на Xcode-managed signing.

## Шаги workflow

1. Job `upload-ios` запускается на `macos-latest` и задает в environment путь к
   Xcode, `XCODEBUILD_EXTRA_FLAGS`, overlay variables, App Store Connect
   secrets и опциональные signing asset secrets.
2. Workflow записывает `ASC_KEY_P8` в
   `$RUNNER_TEMP/asc/AuthKey_${ASC_KEY_ID}.p8`, ограничивает права файла и
   экспортирует `ASC_KEY_PATH` через `$GITHUB_ENV`.
3. Validation step проверяет наличие base bundle identifier, development team
   и App Store Connect key fields до дорогих шагов сборки.
4. `ci_scripts/ci_pre_xcodebuild.sh` вызывает
   `scripts/render_overlay_local_xcconfig.sh`. Скрипт генерирует ignored-файл
   `Config/Overlay.local.xcconfig` из переменных окружения, поэтому CI может
   использовать приватные bundle IDs и team ID без изменения tracked-файлов.
5. Если `ENABLE_LOCAL_SIGNING_ASSETS=true`, запускается
   `scripts/install_apple_signing_assets.sh`:
   - декодирует `BUILD_CERTIFICATE_BASE64` в
     `$RUNNER_TEMP/build_certificate.p12`;
   - создает и разблокирует временный
     `$RUNNER_TEMP/app-signing.keychain-db`;
   - импортирует `.p12` в этот keychain;
   - задает key partition list для Apple signing tools;
   - делает временный keychain default user keychain на время job;
   - проверяет, что импортирована хотя бы одна валидная code signing identity;
   - декодирует `APPLE_PROVISIONING_PROFILES_ARCHIVE_BASE64` и распаковывает
     profiles в `~/Library/MobileDevice/Provisioning Profiles`.
6. `make archive_ios` запускает `xcodebuild archive` для scheme `SFI`,
   configuration `Release`, destination `generic/platform=iOS`, archive path
   `build/SFI.xcarchive` и передает:
   - `-allowProvisioningUpdates`;
   - App Store Connect auth flags из `ASC_KEY_PATH`, `ASC_KEY_ID` и
     `ASC_KEY_ISSUER_ID`;
   - опциональные `XCODEBUILD_EXTRA_FLAGS`.
7. `make upload_ios` запускает `xcodebuild -exportArchive` с тем же подходом к
   provisioning/authentication и `SFI/Upload.plist`. Этот export plist содержит
   `destination=upload` и `method=app-store-connect`, поэтому export и upload в
   TestFlight выполняются одной командой.

## Подготовка optional local assets

Если проекту нужны локальные signing assets, подготовьте secrets из доверенных
локальных файлов и сохраните в GitHub только base64-текст.

Для `.p12` certificate:

```sh
base64 -i path/to/certificate.p12 | pbcopy
```

Для provisioning profiles положите только нужные проекту profiles во временную
директорию и упакуйте их:

```sh
tar -czf apple-profiles.tar.gz *.mobileprovision *.provisionprofile
base64 -i apple-profiles.tar.gz | pbcopy
```

Workflow декодирует эти значения на runner и не записывает их в репозиторий.
Нельзя коммитить `Config/Overlay.local.xcconfig`, certificates, provisioning
profiles, generated archives или export logs с приватными identifiers.

## Чеклист для переноса

Чтобы повторить этот подход в другом iOS-проекте:

1. Добавьте ignored local config или другой bridge из environment variables в
   Xcode settings для bundle IDs и `DEVELOPMENT_TEAM`.
2. Держите tracked default config publish-safe: placeholders или нейтральные
   значения без приватных identifiers.
3. Записывайте `.p8` ключ App Store Connect из secret в `$RUNNER_TEMP` и
   передавайте `-authenticationKeyPath`, `-authenticationKeyID` и
   `-authenticationKeyIssuerID` в archive/export команды.
4. Используйте `-allowProvisioningUpdates` для `xcodebuild archive` и
   `xcodebuild -exportArchive`.
5. Для TestFlight uploads используйте export options plist с
   `method=app-store-connect` и `destination=upload`.
6. Если automatic signing недостаточно, импортируйте `.p12` во временный
   keychain и установите provisioning profiles до archive step.
7. Проверяйте обязательные variables/secrets в начале job, до dependency build
   или долгого archive.
8. Храните generated config и signing assets только в ignored paths или
   `$RUNNER_TEMP`.

Главная граница ответственности: репозиторий описывает форму подписания, а все
приватные значения подставляются GitHub variables/secrets во время выполнения
workflow.
