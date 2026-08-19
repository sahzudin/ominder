import assert from "node:assert/strict"
import fs from "node:fs"

const panelSource = fs.readFileSync(new URL("../Panel.qml", import.meta.url), "utf8")
const textBlocks = panelSource.match(/^\s*Text \{[\s\S]*?^\s*\}/gm) || []

assert.ok(textBlocks.length > 0, "Panel.qml must contain Text elements")

for (const block of textBlocks) {
  assert.match(
    block,
    /^\s*textFormat:\s*Text\.PlainText\s*$/m,
    "every Text element must render plain text so reminder content cannot trigger URL loads"
  )
}

console.log("QML security tests passed")
