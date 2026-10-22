// Starts `eggc lsp` and connects it to VS Code: go to definition, hover,
// outline and live diagnostics for .egg files.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

const mtime = (file) => fs.statSync(file).mtimeMs;

// A Spinel-built build/bin/eggc, used only when it is newer than every
// compiler source, so a stale build never answers for edited sources.
function freshNative(root) {
  const native = path.join(root, "build", "bin", "eggc");
  if (!fs.existsSync(native)) return null;
  const libDir = path.join(root, "lib", "egg");
  const sources = [path.join(root, "bin", "eggc"), path.join(root, "lib", "egg.rb")].concat(
    fs.readdirSync(libDir).map((f) => path.join(libDir, f))
  );
  const built = mtime(native);
  return sources.every((src) => !fs.existsSync(src) || mtime(src) <= built) ? native : null;
}

// The egg.serverPath setting, else (in an open egg checkout) a fresh
// native build/bin/eggc or bin/eggc, else eggc on PATH.
function serverPath() {
  const configured = vscode.workspace.getConfiguration("egg").get("serverPath");
  if (configured) return configured;
  for (const folder of vscode.workspace.workspaceFolders || []) {
    const root = folder.uri.fsPath;
    const native = freshNative(root);
    if (native) return native;
    const candidate = path.join(root, "bin", "eggc");
    if (fs.existsSync(candidate)) return candidate;
  }
  // Ruby is given the script's path, so look eggc up on PATH ourselves.
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    const candidate = path.join(dir, "eggc");
    if (dir && fs.existsSync(candidate)) return candidate;
  }
  return "eggc";
}

// bin/eggc is a Ruby script; a Spinel build is a native executable.
function isScript(file) {
  try {
    const fd = fs.openSync(file, "r");
    const head = Buffer.alloc(2);
    fs.readSync(fd, head, 0, 2, 0);
    fs.closeSync(fd);
    return head.toString() === "#!";
  } catch {
    return false;
  }
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

// The command line that runs eggc: [program, ...leading args], or null
// when eggc is a Ruby script and no Ruby 3+ is found.
function eggcCommand() {
  const eggc = serverPath();
  if (!isScript(eggc)) return [eggc];
  const ruby = findRuby();
  return ruby ? [ruby, eggc] : null;
}

const shellQuote = (s) => "'" + s.replace(/'/g, "'\\''") + "'";

function activate(context) {
  const cmd = eggcCommand();
  // Lets tasks.json run the same eggc: ${command:egg.eggc} build ...
  context.subscriptions.push(
    vscode.commands.registerCommand("egg.eggc", () => (cmd || ["bin/eggc"]).map(shellQuote).join(" "))
  );
  if (!cmd) {
    vscode.window.showErrorMessage(
      "Egg: eggc needs Ruby 3.0 or newer and none was found. Install one, set egg.rubyPath, or build a native eggc with Spinel."
    );
    return;
  }
  client = new LanguageClient(
    "egg",
    "Egg",
    { command: cmd[0], args: cmd.slice(1).concat(["lsp"]) },
    { documentSelector: [{ scheme: "file", language: "egg" }] }
  );
  client.start().catch((err) => {
    vscode.window.showErrorMessage(
      `Egg: could not start '${cmd.join(" ")} lsp' (${err.message}). Check egg.serverPath and egg.rubyPath.`
    );
  });
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
