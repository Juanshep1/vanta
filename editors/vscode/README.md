# Vanta for VS Code

Syntax highlighting for `.va` files, plus the Vanta language server (`vanta lsp`):
errors as you type, completion of keywords/builtins/your own names, hover docs,
go-to-definition (also into imported files), an outline of functions/types/tests,
and Format Document (the same rules as `vanta fmt`).

## Install from this folder

```
cd editors/vscode
npm install                       # fetches vscode-languageclient
npx @vscode/vsce package          # makes vanta-language-6.0.0.vsix
code --install-extension vanta-language-6.0.0.vsix
```

Or, for a quick try without packaging: copy (or symlink) this folder into
`~/.vscode/extensions/vanta-language` and run `npm install` inside it.

The extension runs `vanta lsp`, so the `vanta` launcher must be on your PATH — or set
**Vanta: Path** (`vanta.path`) to the full path of the `vanta` launcher or `vanta.py`.

Commands: **Vanta: Run This File** and **Vanta: Run Tests In This File**.
