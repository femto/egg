// Starts `eggc lsp` and connects it to VS Code: go to definition, hover,
// outline and live diagnostics for .egg files.
const fs = require("fs");
const path = require("path");
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

// The egg.serverPath setting, else bin/eggc in an open egg checkout,
// else eggc on PATH.
function serverPath() {
  const configured = vscode.workspace.getConfiguration("egg").get("serverPath");
  if (configured) return configured;
  for (const folder of vscode.workspace.workspaceFolders || []) {
    const candidate = path.join(folder.uri.fsPath, "bin", "eggc");
    if (fs.existsSync(candidate)) return candidate;
  }
  return "eggc";
}

function activate(context) {
  const command = serverPath();
  client = new LanguageClient(
    "egg",
    "Egg",
    { command, args: ["lsp"] },
    { documentSelector: [{ scheme: "file", language: "egg" }] }
  );
  client.start().catch((err) => {
    vscode.window.showErrorMessage(
      `Egg: could not start '${command} lsp' (${err.message}). Set egg.serverPath to your eggc.`
    );
  });
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
