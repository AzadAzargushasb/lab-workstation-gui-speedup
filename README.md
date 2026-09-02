# lab-workstation-gui-speedup

Diagnose and fix a specific, very common Linux workstation problem: **desktop applications
silently rendering on the CPU while a perfectly good GPU sits idle.**

The symptom is an office suite or image viewer that crawls, on a machine with plenty of
hardware, where the same files open fine on Windows. Nothing errors. Nothing is obviously
broken. The applications have just quietly given up on the graphics card.

On the workstation these scripts were written for, an office suite was rendering every pixel
of every slide on a single 2.2 GHz CPU core via SwiftShader — Chromium's software rasterizer —
because the engine it is built on blocklists the NVIDIA proprietary driver on Linux by
default. The GPU was at 13%. Alongside that: 21 leaked editor processes burning ~103% CPU
continuously (the oldest alive for 7 days), image files set to open in a **web browser**, and
no archive handler registered at all — which is why "the file manager can't unzip" turned out
to be one missing package.

**Nothing here modifies your documents or images.** Every change is to applications and their
settings, and all of it is reversible.

---

## What's in this repo

| File | Purpose |
|---|---|
| [`gui_perf_check.sh`](gui_perf_check.sh) | **Diagnostic only.** Reports PASS / WARN / FAIL for the graphics stack, per-application GPU use, leaked processes, file associations and thumbnail settings. Installs nothing, changes nothing, kills nothing — safe to run anywhere and safe to share with anyone. |
| [`gui_perf_fix.sh`](gui_perf_fix.sh) | **Driver.** Runs the steps below in order and passes your flags through. Dry-run by default. |
| [`steps/01_clean_stale_editors.sh`](steps/01_clean_stale_editors.sh) | Reclaims leaked OnlyOffice/CEF processes. `SIGTERM`, wait, then `SIGKILL` only the survivors. ⚠ Can close open document windows. |
| [`steps/02_install_viewer_stack.sh`](steps/02_install_viewer_stack.sh) | Installs GPU-capable image viewers, LibreOffice, and the missing archive helper. Repo packages always; AUR opt-in. |
| [`steps/03_enable_gpu_accel.sh`](steps/03_enable_gpu_accel.sh) | **The core fix.** Forces OnlyOffice past Chromium's GPU blocklist and switches LibreOffice to Skia-on-Vulkan. |
| [`steps/04_fix_file_associations.sh`](steps/04_fix_file_associations.sh) | Points images at a real viewer instead of a browser, and registers an archive handler. |
| [`steps/05_tune_dolphin_previews.sh`](steps/05_tune_dolphin_previews.sh) | Caps file-manager thumbnail size so it stops decoding 100 MB images to draw icons. |
| [`steps/_common.sh`](steps/_common.sh) | Shared hardware detection and the dry-run plumbing. Sourced by everything; not run directly. |
| [`uninstall.sh`](uninstall.sh) | Restores every setting from backups. Prints, but never runs, the package-removal command. |
| [`GUI_PERFORMANCE_ARCHLINUX_NOTES_2026-09-02.md`](GUI_PERFORMANCE_ARCHLINUX_NOTES_2026-09-02.md) | **The full write-up.** How it was diagnosed (including the two wrong hypotheses), every concept explained from zero, every flag decoded, verification, troubleshooting, and undo. |

---

## Quick start

```bash
git clone https://github.com/AzadAzargushasb/lab-workstation-gui-speedup.git
cd lab-workstation-gui-speedup

./gui_perf_check.sh              # 1. what is actually wrong on THIS machine?
./gui_perf_fix.sh --with-aur     # 2. preview every fix — changes nothing
./gui_perf_fix.sh --with-aur --apply   # 3. apply

# 4. fully quit and reopen your office app from the applications MENU, then:
./gui_perf_check.sh              # the app must now be listed as a GPU process
```

**Everything is dry-run by default.** Running any script without `--apply` prints exactly what
it would do and changes nothing. Read that output before applying.

Reclaiming leaked processes is deliberately *not* part of a default run, because it can close
document windows. Add `--clean`, or run step 01 on its own, when you are ready:

```bash
./steps/01_clean_stale_editors.sh          # list what would be killed
./steps/01_clean_stale_editors.sh --apply  # ⚠ save open work first
```

---

## Does this apply to my machine?

Run `./gui_perf_check.sh` — that is what it is for, and it cannot break anything. Broadly:

**Likely yes if** you are on Linux with a discrete GPU, and an office suite or image viewer
feels far slower than the hardware suggests it should — especially if the same files behave
fine on Windows, or your GPU sits near-idle while a CPU core is pinned.

**Probably not if** your GPU already shows the application in `nvidia-smi`, or you have no GPU
at all. The check will tell you plainly, and each step skips itself with a reason when it does
not apply.

**Portability.** The scripts detect the GPU vendor, distro, desktop environment, available
package managers, and which applications are actually installed, then skip what does not
apply rather than failing. They were developed and verified on **Arch Linux + KDE Plasma 6 +
X11 + NVIDIA**; on other combinations the detection logic is written to be safe but is
untested. Package installation is implemented for Arch-family distros only — elsewhere the
script prints the equivalent package names and exits without touching anything.

---

## What this does *not* fix

**The first open of a very large image will still take seconds.** A PNG is a single
sequential compressed stream: it cannot be decoded in parallel, cannot be decoded in part, and
cannot yield a cheap thumbnail. On the reference machine a 187-megapixel PNG needs ~4.75
seconds of pure single-threaded CPU to decompress, and no choice of application changes that
while the file remains a PNG.

What does change is everything *after* the decode — panning, zooming and redrawing move to the
GPU and become fluid. The honest expectation is **"slow to open once, then smooth"**, not
"instant". Making the open itself fast needs pyramidal or tiled image formats, which means
converting your files; that is out of scope here by design.

**LibreOffice is offered as a test, not a verdict.** It brings native code and GPU rendering,
but its OOXML fidelity is generally weaker than OnlyOffice's. If you edit `.pptx`/`.xlsx` files
and reopen them in Microsoft Office, fidelity matters more than speed. These scripts install it
*alongside* your existing suite and never remove anything — open the same real file in both and
keep whichever wins.

---

## Safety

- Dry-run by default; `--apply` is required to change anything.
- Every modified config file is backed up first with a UTC timestamp.
- Original file associations are recorded before being changed.
- `uninstall.sh` restores everything from those backups.
- Packages are never removed automatically — the command is printed for you to decide.
- No user data is read, modified, moved, or transmitted.

## License

MIT — see [LICENSE](LICENSE).
