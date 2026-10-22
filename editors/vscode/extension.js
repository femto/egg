// Starts `eggc lsp` and connects it to VS Code: go to definition, hover,
// outline and live diagnostics for .egg files.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;
let ruby;

// The egg.serverPath setting, else bin/eggc in an open egg checkout,
// else eggc on PATH.
function serverPath() {
  const configured = vscode.workspace.getConfiguration("egg").get("serverPath");
  if (configured) return configured;
  for (const folder of vscode.workspace.workspaceFolders || []) {
    const candidate = path.join(folder.uri.fsPath, "bin", "eggc");
    if (fs.existsSync(candidate)) return candidate;
  }
  // Ruby is given the script's path, so look eggc up on PATH ourselves.
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    const candidate = path.join(dir, "eggc");
    if (dir && fs.existsSync(candidate)) return candidate;
  }
  return "eggc";
}

function rubyVersion(candidate) {
  try {
    return execFileSync(candidate, ["-e", "print RUBY_VERSION"], { timeout: 5000 }).toString();
  } catch {
    return null;
  }
}

// eggc needs Ruby 3.0+. VS Code started from the Dock often lacks the
// shell's PATH and finds macOS's /usr/bin/ruby (2.6), so also look where
// version managers and Homebrew put Ruby.
function findRuby() {
  const configured = vscode.workspace.getConfiguration("egg").get("rubyPath");
  if (configured) return configured;
  const home = os.homedir();
  const candidates = [
    "ruby",
    path.join(home, ".rbenv", "shims", "ruby"),
    path.join(home, ".local", "share", "mise", "shims", "ruby"),
    path.join(home, ".asdf", "shims", "ruby"),
    path.join(home, ".rvm", "rubies", "default", "bin", "ruby"),
    "/opt/homebrew/opt/ruby/bin/ruby",
    "/usr/local/opt/ruby/bin/ruby",
    "/usr/local/bin/ruby",
  ];
  for (const candidate of candidates) {
    const version = rubyVersion(candidate);
    if (version && parseInt(version, 10) >= 3) return candidate;
  }
  return null;
}

function activate(context) {
  ruby = findRuby();
  // Lets tasks.json run eggc with the same Ruby: ${command:egg.rubyPath}.
  context.subscriptions.push(
    vscode.commands.registerCommand("egg.rubyPath", () => ruby || "ruby")
  );
  if (!ruby) {
    vscode.window.showErrorMessage(
      "Egg: eggc needs Ruby 3.0 or newer and none was found. Install one, or set egg.rubyPath."
    );
    return;
  }
  const eggc = serverPath();
  client = new LanguageClient(
    "egg",
    "Egg",
    { command: ruby, args: [eggc, "lsp"] },
    { documentSelector: [{ scheme: "file", language: "egg" }] }
  );
  client.start().catch((err) => {
    vscode.window.showErrorMessage(
      `Egg: could not start '${ruby} ${eggc} lsp' (${err.message}). Check egg.rubyPath and egg.serverPath.`
    );
  });
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
