# MF-Linkgrabber
grabs MF links and makes them ready to use in Jdownloader or any other downloader

 A single .bat file with a small dark-mode window. Paste MediaFire folder and/or file links and it gives you a list of direct download links to copy into JDownloader or any downloader. Handy when pasting the folder link straight into your downloader gets blocked by Cloudflare. How to use it: copy everything paste into a notepad and save as .bat

How it works: it opens your own Edge/Chrome in a separate profile, lists every file in the folder (subfolders included), and resolves each file’s direct link. If MediaFire shows a Cloudflare check, you click it yourself once.

Features

    Folders and single file links, mixed in one list

    Per-file status: OK / Removed / Password-protected / Blocked / Unresolved

    Names, sizes, total size, and duplicate detection (by hash)

    Retry/resume, and a Stop button that keeps what’s done

    Copy links, export to .txt (links only or a full report), and an automatic backup of every run, including your original source links

    Dark, high-contrast UI with adjustable text size and keyboard shortcuts

Requirements: Windows 10/11 with Edge or Chrome. Nothing to install: it only uses PowerShell, which ships with Windows.

direct links expire, so paste them into your downloader soon after converting. It’s a plain-text script, so you can read exactly what it does before running it. Windows SmartScreen may warn about the .bat. Only use it for files you have the right to download.

AI disclosure: it was made with Claude to scracth my own needs if you like it, use it at your discretion. 

Download the latest release https://github.com/RunTestWork/MF-Linkgrabber/releases/tag/a
