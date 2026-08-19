import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const installerPath = path.join(repositoryRoot, "install.sh")
const uninstallerPath = path.join(repositoryRoot, "uninstall.sh")
const hasInstaller = fs.existsSync(installerPath)
const hasUninstaller = fs.existsSync(uninstallerPath)

assert.equal(
  hasInstaller,
  hasUninstaller,
  "install.sh and uninstall.sh must be added or removed together"
)

const persistentSharedTargets = [
  "omarchy-menu.jsonc",
  ".config/omarchy/extensions",
  ".config/omarchy/shell.json"
]

const runtimeFiles = ["BarWidget.qml", "Panel.qml", "Model.js"]
const runtimeSource = runtimeFiles
  .map(file => fs.readFileSync(path.join(repositoryRoot, file), "utf8"))
  .join("\n")

for (const target of persistentSharedTargets) {
  assert.equal(
    runtimeSource.includes(target),
    false,
    `runtime code must not persist shared Omarchy configuration: ${target}`
  )
}

if (hasInstaller) {
  const installer = fs.readFileSync(installerPath, "utf8")
  const uninstaller = fs.readFileSync(uninstallerPath, "utf8")

  for (const target of persistentSharedTargets) {
    if (installer.includes(target)) {
      assert.ok(
        uninstaller.includes(target),
        `uninstall.sh must clean the shared target modified by install.sh: ${target}`
      )
    }
  }
}

console.log("Removal policy tests passed")
