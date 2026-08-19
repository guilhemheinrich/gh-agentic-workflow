# Installing eza

**Read this only if `command -v eza` comes back empty.** Every command below was
taken from the upstream `INSTALL.md` (eza-community/eza) rather than from memory;
the canonical list, including Gentoo, openSUSE, Termux, MacPorts, Pixi, Flox and
manual tarballs, lives at <https://github.com/eza-community/eza/blob/main/INSTALL.md>.

| Platform            | Command                                  |
| ------------------- | ---------------------------------------- |
| macOS (Homebrew)    | `brew install eza`                       |
| Arch Linux          | `pacman -S eza`                          |
| Fedora              | `sudo dnf install eza`                   |
| Void Linux          | `sudo xbps-install eza`                  |
| Nix                 | `nix profile install nixpkgs#eza`        |
| Windows (Winget)    | `winget install eza-community.eza`       |
| Windows (Scoop)     | `scoop install eza`                      |
| Any Rust toolchain  | `cargo install eza`                      |

Debian and Ubuntu need a third-party apt repository (`deb.gierens.de`) with its
GPG key installed first. That is six commands including a `sudo tee` into
`/etc/apt/sources.list.d/`, so follow the upstream instructions directly rather
than a copy that can drift: <https://github.com/eza-community/eza/blob/main/INSTALL.md#debian-and-ubuntu>.
On a machine with a Rust toolchain, `cargo install eza` avoids the repository
entirely.

## Verify

```bash
eza --version && bash scripts/eza-docs.sh --refresh
```

The second half builds the local documentation cache this skill relies on, and
fails loudly if `man eza` is unavailable — some minimal container images ship the
binary without its man pages, in which case `eza-docs.sh --grep` still works
against `--help` alone.

## Icons need a font, not a flag

`--icons` emits Nerd Font glyphs. Without a patched font installed **and selected
in the terminal profile**, they render as tofu boxes. That is a font problem, not
an eza problem, and it is a reason to leave icons off in any output destined for
a chat transcript — see §3 of [SKILL.md](SKILL.md).
