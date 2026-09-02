# GUI performance — Arch Linux + KDE Plasma (analyze06)

**Started:** 2026-09-02
**Machine:** `analyze06` (Arch Linux rolling, Xeon E5-2699 v4 @ 2.2 GHz / 88 threads,
251 GB RAM, NVIDIA GTX 1080, KDE Plasma 6.7.4 on X11, ext4 on local RAID)
**Symptom:** Gwenview and OnlyOffice unusably slow; the same `.pptx` files open smoothly in
Microsoft PowerPoint on a Windows PC
**Scope:** make image viewing, office documents, and file browsing fast again **without
modifying a single data file**
**Related:** `LATEX_VSCODE_ARCHLINUX_SETUP_NOTES_2026-08-22.md`,
`MATLAB_R2026a_ARCHLINUX_FIX_NOTES_2026-08-12.md` (same machine)

This file is the **operational record**: how the problem was diagnosed, what every command
does and why, the background concepts explained from zero, and exactly how to undo all of it.
The scripts referenced live beside this file and are published as
[`lab-workstation-gui-speedup`](https://github.com/AzadAzargushasb/lab-workstation-gui-speedup)
so the other `analyze0X` machines can use them.

---

## 0. Status at a glance

| # | Finding                                                        | State |
| - | -------------------------------------------------------------- | ----- |
| 1 | OnlyOffice rendering on the CPU via SwiftShader                | ❌ **CONFIRMED** — §3.4 |
| 2 | Gwenview not bound to the NVIDIA driver                        | ❌ **CONFIRMED** — §3.4 |
| 3 | 21 leaked OnlyOffice processes: 14.8 GB, ~103% CPU, oldest 167h | ❌ **CONFIRMED** — §3.5 |
| 4 | PNG/JPEG opening in Chromium, not an image viewer              | ❌ **CONFIRMED** — §3.6 |
| 5 | No handler at all for `application/zip`; Ark not installed     | ❌ **CONFIRMED** — §3.6 |
| 6 | No Dolphin thumbnail size cap                                  | ⚠️ **CONFIRMED** — §3.6 |
| 7 | RustDesk suspected as the cause                                | ✅ **RULED OUT** — §3.2 |
| 8 | File size suspected as the cause                               | ✅ **RULED OUT** — §3.3 |
| 9 | System Pillow broken (`import PIL` fails)                      | ⚠️ **UNRELATED, UNFIXED** — §7 |

**The one thing to take away:** the GPU was sitting at 13% while a single 2.2 GHz CPU core
drew every pixel of every slide by hand.

---

## 1. The one-paragraph summary

`analyze06` has a GTX 1080 with a working proprietary driver and working Vulkan, and **not
one** of the slow applications was using it. OnlyOffice had silently fallen back to
SwiftShader — Chromium's pure-software rasterizer — because the CEF engine it is built on
blocklists the NVIDIA proprietary driver on Linux by default. Gwenview had loaded the OpenGL
dispatch libraries but never bound the NVIDIA driver behind them. Both were therefore
rasterizing on the CPU, single-threaded, on a processor whose cores run at only 2.2 GHz.
That is why the identical `.pptx` is fluid in PowerPoint on Windows (which renders through
DirectX on the GPU) and painful here. Three cheaper problems compounded it: 21 leaked
OnlyOffice processes burning ~103% CPU continuously, image files associated with Chromium
instead of an image viewer, and no archive handler registered at all — which is the entire
reason unzipping from Dolphin appeared impossible. **The fix is entirely configuration; no
data file was touched.**

---

## 2. Before you start: what a "fast" or "slow" application really means here

Two ideas explain almost everything in this document.

**Rasterization.** Everything you see is ultimately a grid of coloured pixels. Turning
shapes, glyphs and images into that grid is called *rasterization*. A GPU is a chip built to
do exactly this, thousands of times faster than a general-purpose CPU. When an application
rasterizes on the GPU it is "hardware accelerated"; when it does the same arithmetic on the
CPU it is "software rendered". The output looks identical. Only the speed differs — often by
one or two orders of magnitude.

**Single-threaded work.** This machine has 88 hardware threads, which sounds enormous. But
rasterizing one window is a *serial* job: it runs on **one** core. What matters is therefore
not how many cores you have but how fast *one* core is, and at 2.2 GHz these are individually
slow — that is the trade Intel made to fit 22 of them on a die. For this workload,
`analyze06` has close to the worst possible CPU shape: a great many slow cores where you
needed one fast one. It is superb at running 88 FSL jobs at once and poor at redrawing a
slide.

Put together: an application that quietly stops using the GPU on this machine does not get
a bit slower. It falls off a cliff.

---

## 3. How the problem was diagnosed

This section is the record of what was actually done, including the two hypotheses that
turned out to be wrong. Both were worth testing, and ruling them out is what made the real
cause findable.

### 3.1 Establishing the ground truth

```bash
uname -a; cat /etc/os-release | head -5
lscpu | grep -E "Model name|^CPU\(s\)|Thread|Core|MHz"
free -h
lspci -k | grep -A3 -iE "vga|3d|display"
```

`lscpu` reports the CPU model and topology; `lspci -k` lists PCI devices, and the `-k` flag
adds **"Kernel driver in use"** — the single most useful line, because a graphics card with
no driver bound, or with the wrong one, cannot accelerate anything.

Result: Xeon E5-2699 v4 @ 2.2 GHz, 88 threads, 251 GB RAM, GTX 1080 with
`Kernel driver in use: nvidia`. So the hardware and driver were fine, which immediately made
"the GPU is broken" an unlikely explanation and pointed at the applications instead.

### 3.2 Hypothesis 1 — the remote desktop. RULED OUT.

The session was reached over SSH, and a remote-desktop server was running:

```bash
ps aux | grep -i rustdesk | grep -v grep
```

This mattered because a remote desktop re-encodes the screen as video on every repaint.
Panning a very large image full-screen is close to the worst case for a video codec, so
RustDesk was a genuinely plausible culprit.

**It was ruled out by evidence, not by argument:** the user reported the same slowness while
sitting physically at the machine. A cause that is absent when the symptom is present is not
the cause. RustDesk remains background load, but it is not the problem, and nothing in this
repo touches it.

### 3.3 Hypothesis 2 — the files are simply too big. RULED OUT.

The files really are extreme:

```bash
find -L ~/data/Fusi_mouse -name "*.pptx" -printf "%s\n" \
  | awk '{n++; s+=$1} END{printf "count=%d total=%.1f GB mean=%.0f MB\n", n, s/1073741824, (s/n)/1048576}'
file -b <a figure>.png            # PNG dimensions without decoding the whole file
```

- **762 `.pptx`, 166.7 GB total, mean 224 MB.** The largest is **7.7 GB with 1,548 slides and
  658 embedded images** averaging 7 MB each.
- **285 PNGs over 20 MB.** The largest is **32400 × 10800 pixels — 350 megapixels**, which is
  **1.3 GB** once decompressed into memory (width × height × 4 bytes for red, green, blue and
  alpha).

It would be easy to stop here and declare the files impossible. **The user's own observation
refuted that:** the same decks open smoothly in PowerPoint on Windows. A file that one
program handles fluidly is not too big; the other program is doing something worse. That
single data point is what redirected the whole investigation from the files to the renderer,
and it is why "just make the files smaller" was never the answer.

### 3.4 The actual cause: software rendering

The decisive check. `nvidia-smi` lists every process the GPU driver currently knows about —
that is, every process actually using the GPU:

```bash
nvidia-smi                       # look at the "Processes:" table at the bottom
nvidia-smi | grep -i editor      # is OnlyOffice there?
```

**OnlyOffice did not appear. Neither did Gwenview.** Xorg, KWin, plasmashell, VS Code and
RustDesk all did. So the applications were running, drawing windows, and doing it without
the GPU.

Confirmed from the other direction by looking at which libraries the running processes had
loaded. `/proc/<pid>/maps` lists every file mapped into a process's memory — an exact,
unfakeable record of what code it is running:

```bash
PID=$(pgrep -f DesktopEditors | head -1)
grep -oE "libGLX_nvidia[^ ]*|swiftshader[^ ]*" /proc/$PID/maps | sort -u
```

- OnlyOffice had **`libvk_swiftshader.so`** mapped. SwiftShader is Chromium's software
  rasterizer: a complete implementation of a GPU, in software, running on the CPU. A process
  that has loaded it has definitively given up on hardware acceleration.
- Gwenview had `libGLX.so` and `libGLdispatch.so` but **not `libGLX_nvidia.so`**. This
  distinction is subtle and important. `libGLX.so` is a *dispatcher* — a switchboard that
  forwards OpenGL calls to whichever vendor driver is in use. Loading the switchboard but
  never the NVIDIA driver behind it means the calls went to a software fallback instead.

Meanwhile the card was idle:

```bash
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv
# 13 %, 2291 MiB / 8192 MiB
```

**Why CEF refuses the GPU.** OnlyOffice is built on CEF, the embedded version of Chrome.
Chrome maintains a *blocklist* of graphics driver and card combinations it considers
unreliable, and the NVIDIA proprietary driver on Linux is on it. When CEF consults that list
and declines the GPU, it does not warn anyone — it switches to SwiftShader and carries on,
producing pixel-identical output at a fraction of the speed. This is why the slowness is so
confusing from the outside: nothing is broken, nothing errors, it is just quietly doing the
work the slow way.

That behaviour can be overridden, which is what §5.2 does.

### 3.5 The compounding problem: leaked processes

```bash
ps -eo pid,pcpu,rss,etime,comm --sort=-etime | grep -E "editors_helper|DesktopEditors"
```

`etime` is elapsed time since the process started — the giveaway. The result:

- **21 processes**, **14.8 GB** resident, **~103% CPU** *continuously*
- **16 of them older than 24 hours**; the oldest alive **167 hours ≈ 7 days**
- 19 were CEF **zygotes** — a zygote is a pre-initialised template process kept around so new
  tabs or windows can be forked quickly. A zygote should be *idle*. One consuming 5–6% CPU
  for a week is leaked.

For scale, of the ~180% total CPU the user's account was consuming, ~103% was these dead
processes. The other person on the machine was using 4%. This was self-inflicted, not
contention for a shared box.

### 3.6 The cheap problems nobody had noticed

```bash
xdg-mime query default image/png        # -> chromium.desktop
xdg-mime query default application/zip  # -> (nothing at all)
pacman -Q ark                           # -> error: package 'ark' was not found
```

- **PNG and JPEG were set to open in Chromium.** Double-clicking a 350-megapixel figure
  handed it to a web browser, which has no tiled or level-of-detail rendering and must decode
  the entire image before displaying anything.
- **Nothing was registered for `application/zip`,** and **Ark was not installed.** On KDE the
  *"Extract archive here"* right-click action in Dolphin is provided by Ark. Without it there
  is no extract action at all — which presents as "Dolphin cannot unzip" when in fact the
  helper program is simply absent. This was the entire unzip complaint, and it is one package.
- **No Dolphin thumbnail size cap.** To draw a thumbnail the file manager must fully decode
  the image; with no cap it decodes 120 MB PNGs to paint icons a centimetre wide.

### 3.7 How slow is the decoding itself?

Worth measuring, because it bounds what any fix can achieve:

```bash
cat <file>.png > /dev/null                    # warm the page cache first, to time CPU not disk
time ffmpeg -v error -i <file>.png -f null -  # decode every pixel, discard the output
```

A 13679 × 13679 (187 megapixel) PNG took **4.75 seconds of pure single-threaded CPU** just to
decompress. The 350-megapixel file exceeded ffmpeg's default allocation limits entirely.

**This part cannot be fixed by changing applications**, and §6 explains why.

---

## 4. Background concepts, from zero

Everything a reader needs in order to follow §5, assuming no prior knowledge.

### 4.1 What a rasterizer is, and what "SwiftShader" means

A *rasterizer* turns geometry into pixels. Your GPU has thousands of tiny cores built for
precisely this. **SwiftShader** is Google's implementation of a GPU *in software*: it
produces the same pixels using the CPU, so a browser still works on a machine with no usable
graphics driver. It is a safety net, not a performance option. Seeing `libvk_swiftshader.so`
loaded in a process is proof that the safety net was deployed.

### 4.2 CEF, and why 19 idle processes can burn a core

**CEF** (Chromium Embedded Framework) is the Chrome engine packaged so other applications can
embed it. OnlyOffice is a web application in a private browser. That brings Chrome's
multi-process architecture: one main process plus many helpers, isolated from each other for
robustness.

A **zygote** is a helper started early and held in a ready state so new windows can be forked
from it cheaply. Zygotes should consume no CPU while waiting. When the parent mismanages them
they keep running a render or event loop forever, which is how nineteen processes that are
doing nothing at all can consume a full core between them.

### 4.3 What a MIME default is

A **MIME type** names a kind of file (`image/png`, `application/zip`). Your desktop keeps a
table mapping each type to the application that should open it — the **default handler** —
and `xdg-mime` reads and writes that table. Nothing validates that the choice is *sensible*:
if a browser registers itself for `image/png` at install time, every image you double-click
goes to the browser until someone changes it back.

### 4.4 Why a PNG cannot be decoded faster, or in parallel

A PNG is compressed as **one continuous DEFLATE (zlib) stream** covering the whole image.
Decompression is inherently sequential: byte *n* cannot be decoded without having decoded
everything before it, because the format encodes data as back-references into what came
earlier. On top of that, each row of pixels is stored as a *filtered* difference against the
row above, so row *n* needs row *n−1* reconstructed first.

The consequences are firm:

- **You cannot use more cores.** 88 threads do not help; one core does the work.
- **You cannot decode only the visible part.** There is no index into the middle of the stream.
- **You cannot cheaply produce a small version.** Getting a thumbnail means decoding it all.

This is why the ~5 second first-open cost in §3.7 is irreducible *for a PNG*. Formats built
for huge images — pyramidal TIFF, DeepZoom, the tiled formats used by maps and slide scanners
— solve it by storing pre-computed lower-resolution copies and independently-decodable tiles.
Converting to one of those was explicitly out of scope here, because no data file was to be
modified. `vipsdisp` (§5.3) is the best available answer within that constraint: it cannot
avoid the initial decode, but everything afterwards becomes fast.

### 4.5 Skia and Vulkan (for LibreOffice)

**Skia** is a 2D graphics library (also used by Chrome and Android). **Vulkan** is a modern
low-level API for talking to a GPU. LibreOffice can draw its interface and documents through
Skia, and Skia can target either the CPU or the GPU via Vulkan. So LibreOffice has *two*
relevant switches, and getting only the first one right leaves you no better off:

| Setting | Wanted | Meaning |
|---|---|---|
| `UseSkia` | **true** | use the Skia renderer at all |
| `ForceSkiaRaster` | **false** | let Skia use the GPU; `true` forces CPU drawing |

This machine reports Vulkan 1.4.312 on the GTX 1080, so the GPU path is available.

---

## 5. The fixes

Every script is **dry-run by default** — running it bare prints what it *would* do and
changes nothing — matching the `clean_feat_reruns.sh` convention in the parent code tree.
`--apply` is what actually acts.

### 5.0 The command sheet

```bash
cd ~/data/Fusi_mouse/IMG-PROC/code/viewer_perf_2026-09

# ── 1. DIAGNOSE. Read-only, changes nothing, safe to run any time. ──
./gui_perf_check.sh

# ── 2. PREVIEW every fix. Still changes nothing. ──
./gui_perf_fix.sh --with-aur

# ── 3. RECLAIM leaked processes. ⚠ CLOSES OPEN DOCUMENT WINDOWS — save work first. ──
./steps/01_clean_stale_editors.sh                  # list what would be killed
./steps/01_clean_stale_editors.sh --apply          # kill anything older than 24h

# ── 4. INSTALL the viewers + the missing archive helper. ──
./steps/02_install_viewer_stack.sh --with-aur --apply

# ── 5. THE CORE FIX: move rendering onto the GPU. ──
./steps/03_enable_gpu_accel.sh --apply

# ── 6. Point images and archives at the right programs. ──
./steps/04_fix_file_associations.sh --apply

# ── 7. Stop Dolphin thumbnailing enormous images. ──
./steps/05_tune_dolphin_previews.sh --apply

# ── 8. GATE: fully quit OnlyOffice/LibreOffice, reopen from the MENU, then verify. ──
./gui_perf_check.sh
```

Steps 4–7 can also be run in one go with `./gui_perf_fix.sh --with-aur --apply`. Step 3 is
kept separate and opt-in (`--clean`) precisely because it can close windows.

### 5.1 Reclaiming the leaked processes

```bash
./steps/01_clean_stale_editors.sh --apply
```

It lists every OnlyOffice process with its age, CPU, memory and — where it can determine it —
the document it has open, so the list is reviewable rather than an opaque wall of PIDs. Then:

1. **`SIGTERM` first.** `kill -TERM` politely asks a process to shut down; it can catch the
   signal, flush state and exit cleanly.
2. **Wait 5 seconds**, then re-check which are still alive.
3. **`SIGKILL` only the survivors.** `kill -KILL` cannot be caught, blocked or cleaned up
   after — the kernel simply removes the process. It is a last resort, never the opening move.

⚠️ **These processes may still own on-screen windows.** Killing one closes it and loses
anything unsaved. Dry-run first, save your work, then apply.

| Flag | Effect |
|---|---|
| *(none)* | dry run — list only |
| `--apply` | actually kill |
| `--older-than N` | change the age threshold from 24 hours to N |
| `--all` | ignore age; target every OnlyOffice process |

### 5.2 The core fix — GPU rendering

```bash
./steps/03_enable_gpu_accel.sh --apply
```

**OnlyOffice.** The flags below were verified to exist in the bundled `libcef.so` before
being used — not assumed:

| Flag | What it does |
|---|---|
| `--ignore-gpu-blocklist` | use the GPU even though this driver is on Chrome's blocklist. **This is the one that matters.** |
| `--enable-gpu-rasterization` | rasterize on the GPU rather than the CPU |
| `--enable-zero-copy` | pass textures to the GPU without an extra CPU-side copy |
| `--disable-software-rasterizer` | refuse to fall back to SwiftShader |

That last flag is deliberate. Without it, a failed GPU setup silently reverts to software and
you learn nothing; with it, failure is loud and diagnosable. If OnlyOffice then refuses to
start, re-run with `--safe-flags` to drop it.

The script writes a **user-level copy** of the launcher to
`~/.local/share/applications/onlyoffice-desktopeditors.desktop` rather than editing the
system file. This needs no root and survives package updates. Note there are **five** `Exec=`
lines in that file — the main entry plus one for each "New document / spreadsheet /
presentation / form" action — and all five are patched, or those menu entries would still
launch without acceleration.

> Because the flags live in the *launcher*, they apply when OnlyOffice is started from the
> applications menu or by opening a file. Launching the binary directly from a terminal
> bypasses the launcher and will still render in software.

**LibreOffice.** Sets `UseSkia=true` and `ForceSkiaRaster=false` (§4.5) in
`~/.config/libreoffice/4/user/registrymodifications.xcu`, backing it up first. Because
LibreOffice rewrites that file when it exits, the script refuses to run while LibreOffice is
open — and **the GUI route is authoritative**:

> **Tools → Options → LibreOffice → View → Graphics Output**
> ☑ *Use Skia for all rendering* ☐ *Force Skia software rendering* ← must stay **unticked**

If the verification in §6 does not show the GPU in use, set it from that menu and trust it
over the file edit.

### 5.3 Faster image viewers

```bash
./steps/02_install_viewer_stack.sh --with-aur --apply
```

| Tool | Source | Why it is faster |
|---|---|---|
| **vipsdisp** | AUR | **Tiled, lazy, level-of-detail rendering** via libvips: it draws only the tiles you are looking at, at the zoom you are looking at — the trick that makes online maps feel instant. Best option for gigapixel images. |
| **qimgv** | AUR | OpenGL scaling and panning. The natural drop-in replacement for Gwenview, same workflow. |
| **imv** | `extra` | OpenGL, lightweight, in the official repos. Lowest-risk thing to try first. |
| **nomacs** | AUR | Qt viewer with good scientific metadata support. Optional (`--extras`). |

### 5.4 Office alternatives, honestly

**LibreOffice is a test, not a verdict.** It gets you native C++ code and GPU rendering, but
its OOXML fidelity is generally *weaker* than OnlyOffice's. Since these decks are edited and
reopened in Microsoft PowerPoint, fidelity is not negotiable. The script installs it
**alongside** OnlyOffice — they coexist without conflict — so open the *same real deck* in
both, compare rendering accuracy as well as speed, and keep whichever wins.

If fidelity disqualifies LibreOffice, two native (non-Chromium) alternatives with strong PPTX
fidelity are available via `--extras`: **WPS Office** (`wps-office`) and **SoftMaker
FreeOffice** (`freeoffice`).

### 5.5 File associations and the unzip fix

```bash
./steps/04_fix_file_associations.sh --apply
```

Points `image/png`, `image/jpeg`, `image/tiff` and `image/webp` at the best installed viewer
(preferring `vipsdisp` → `qimgv` → `imv` → `gwenview`), and registers Ark for `application/zip`
and friends. **Run step 02 first**, or it can only choose from what is already installed.

The previous handler for every type is recorded to `mime_defaults.backup` before anything
changes, so `uninstall.sh` can restore them exactly.

### 5.6 The thumbnail cap

```bash
./steps/05_tune_dolphin_previews.sh --apply        # 5 MB default; --size N to change
```

Sets `MaximumSize` under `[PreviewSettings]` in `~/.config/dolphinrc` (stored in bytes; the
script converts for you), preferring KDE's own `kwriteconfig6` and falling back to editing the
INI directly. 5 MB is comfortably above ordinary screenshots and photos and far below the
figures that cause the stall. The same setting lives in **Settings → Configure Dolphin →
General → Previews**.

---

## 6. What this does *not* fix — read this before judging the result

**The first open of a very large PNG will still take seconds.** §4.4 explains why: a PNG is a
single serial compressed stream that cannot be decoded in parallel or in part. Measured on
this machine, a 187-megapixel PNG needs **4.75 seconds of pure CPU** to decompress, and no
change of application removes that while the file stays a PNG.

What the fixes change is **everything after the decode**. Panning, zooming and redrawing move
onto the GPU and become fluid, instead of re-scaling hundreds of megapixels on one CPU core
for every frame. The honest expectation is:

> **"Slow to open once, then smooth"** — not *"instant"*.

Making the open itself fast would require pyramidal or tiled files, which means converting the
data. That was explicitly ruled out, and this repo respects that.

---

## 7. Verification

"It feels faster" is not evidence. The test is whether the graphics driver reports the
application as a GPU client.

```bash
# BEFORE — returns nothing at all
nvidia-smi | grep -iE "editor|soffice"

# Apply the fixes, then FULLY quit OnlyOffice/LibreOffice (every window),
# and reopen from the applications MENU — not from a terminal (§5.2).

# AFTER — must now list the application
nvidia-smi | grep -iE "editor|soffice"

# Or have it all checked for you:
./gui_perf_check.sh
```

Concretely, in order:

1. `nvidia-smi | grep -i editor` lists an OnlyOffice process. **This is the whole fix.**
2. `ps -eo pid,etime,comm | grep editors_helper` stays near-empty over the following days. If
   leaked zygotes accumulate again, that is an OnlyOffice bug worth reporting upstream.
3. Open the same real deck in OnlyOffice-with-flags and LibreOffice-with-Skia; compare
   smoothness **and fidelity** against PowerPoint on Windows.
4. Open a 32400 × 10800 PNG in Gwenview versus `qimgv`/`vipsdisp`. Judge pan and zoom *after*
   load, per §6.
5. Right-click a `.zip` in Dolphin → **Extract archive here** now exists.
6. Double-click a `.png` → it opens in an image viewer, not Chromium.

---

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `nvidia-smi` still does not list OnlyOffice | The old process is still alive. Quit **every** window (`pkill -f DesktopEditors`) and relaunch from the menu. |
| OnlyOffice will not start after the fix | `--disable-software-rasterizer` is doing its job — GPU init failed. Re-run `./steps/03_enable_gpu_accel.sh --safe-flags --apply`. |
| Launched from a terminal, still slow | Expected. The flags live in the `.desktop` launcher; a direct binary invocation bypasses it (§5.2). |
| LibreOffice Skia setting keeps reverting | It was open when the profile was patched — LibreOffice rewrites that file on exit. Close it completely, or use the GUI route (§5.2). |
| Dolphin still stalls on big folders | Restart it — `killall dolphin` — so the new preview cap is read. |
| Still no "Extract archive here" | Ark was installed after Dolphin started. Restart Dolphin. |
| `qimgv`/`vipsdisp` will not build | They are AUR packages built from source. Check the build log; `imv` from the official repos is a working fallback. |
| Everything is slow again after an update | An update can replace the system `.desktop` file, but the user-level override should win. Re-run `./gui_perf_check.sh` to confirm. |

---

## 9. Unrelated bug found along the way — NOT fixed

System Python's Pillow is broken and will break any plotting script using `/usr/bin/python3`:

```
ImportError: /usr/lib/python3.14/site-packages/PIL/_imaging.cpython-314-x86_64-linux-gnu.so:
undefined symbol: opj_encoder_set_extra_options
```

`python-pillow 12.3.0-1` is linked against a different `openjpeg2` than the installed
`2.5.4-1` — the classic signature of a partial upgrade. The likely fix is a full
`sudo pacman -Syu`, or working inside a conda env. **Left alone deliberately**: a full system
upgrade is a bigger decision than anything else in this document, and it is unrelated to the
GUI problem. Flagged because the figure-generation work runs through Python.

---

## 10. Full undo

```bash
./uninstall.sh              # dry run — show what would be restored
./uninstall.sh --apply      # restore
```

It removes the OnlyOffice launcher override (the system launcher takes over again), restores
the LibreOffice profile and `dolphinrc` from their timestamped backups, and restores the
original file associations from `mime_defaults.backup`.

It deliberately **does not uninstall packages** — it prints the `pacman -Rns` command for you
to run yourself. Removing software is a bigger decision than reverting a setting, other
things may depend on those packages, and this is a shared machine.

It also cannot bring back processes killed in §5.1. Nothing can.
