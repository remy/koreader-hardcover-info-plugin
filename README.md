# Hardcover info for KOReader

Shows details of the open book from [Hardcover](https://hardcover.app):

- title and author
- year published
- series, position, and the other books in it
- description
- community rating

## Install

Copy `hardcoverinfo.koplugin` into KOReader's `plugins` folder and restart.

## API token

1. Create a token with the `read:catalog` scope: <https://hardcover.app/account/api?scope=read:catalog>
2. Either:
   - paste it in **Search → Hardcover book info → API token…**, or
   - save it as `hardcoverinfo.koplugin/token.txt` (easier than typing on an e-reader).

## Use

**Search → Hardcover book info → Show book info**, or assign the *Hardcover book info* gesture.

The book is matched by ISBN, then title and author. If unsure, a list of candidates is shown. The match and details are cached per book; use **Refresh** to re-fetch or **Change matched book…** to fix a wrong match.
