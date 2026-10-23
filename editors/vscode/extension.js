// Vanta for VS Code: starts `vanta lsp` (the Vanta language server) for .va files and adds
// "Vanta: Run This File" / "Vanta: Run Tests In This File" commands.
const vscode = require("vscode");
const path = require("path");

let client = null;

function serverCommand() {
  const configured = vscode.workspace.getConfiguration("vanta").get("path") || "vanta";
  // A path to vanta.py runs through python3; anything else is run directly.
  if (configured.endsWith(".py")) return { command: "python3", args: [configured, "lsp"] };
  return { command: configured, args: ["lsp"] };
}

function runInTerminal(sub) {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "vanta") return;
  editor.document.save().then(() => {
    const { command } = serverCommand();
    const configured = vscode.workspace.getConfiguration("vanta").get("path") || "vanta";
    const exe = configured.endsWith(".py") ? `python3 "${configured}"` : `"${command}"`;
    const term = vscode.window.activeTerminal || vscode.window.createTerminal("Vanta");
    term.show();
    term.sendText(`${exe} ${sub} "${editor.document.fileName}"`);
  });
}

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand("vanta.run", () => runInTerminal("run")));
  context.subscriptions.push(vscode.commands.registerCommand("vanta.test", () => runInTerminal("test")));
  if (!vscode.workspace.getConfiguration("vanta").get("languageServer.enabled", true)) return;
  let lc;
  try {
    lc = require("vscode-languageclient/node");
  } catch (e) {
    vscode.window.showWarningMessage("Vanta: run `npm install` in the extension folder to enable the language server.");
    return;
  }
  const { command, args } = serverCommand();
  const serverOptions = { command, args, transport: lc.TransportKind.stdio };
  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "vanta" }, { scheme: "untitled", language: "vanta" }],
  };
  client = new lc.LanguageClient("vanta", "Vanta Language Server", serverOptions, clientOptions);
  client.start();
  context.subscriptions.push({ dispose: () => client && client.stop() });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
