Drop .ico files for Url shortcuts in this folder.

Reference them from SupportFiles\Shortcuts.json by bare filename in a Url entry's
"IconFile" field, e.g.:

  {
    "Name": "Canva",
    "Type": "Url",
    "Target": "https://www.canva.com",
    "IconFile": "canva.ico"
  }

At install the packaged icons are copied to:
  %ProgramData%\LundsFontanhus\ShortcutDeployment\Icons\

and the .url shortcut's IconFile= line points there, so all users see the icon.

Notes:
- A bare filename (no path) resolves to this Icons folder.
- A rooted path or a value containing a path separator is used as-is, so you can
  still point at a system icon source, e.g. "%SystemRoot%\System32\shell32.dll".
- Optional "IconIndex" (default 0) selects an icon within a multi-icon file. For a
  standalone .ico, leave it at 0.
- .ico is the reliable format for a shortcut icon. .png is not a valid icon
  resource; convert it to .ico first.

This README is just a placeholder so the folder ships in the package. You can
delete it once you add real icons.
