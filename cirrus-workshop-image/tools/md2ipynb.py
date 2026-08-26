#!/usr/bin/env python3
"""Generate the notebook edition of the workshop pages from the Markdown ones.

The Markdown is the source of truth. Notebooks are a build artifact, so the two
editions cannot drift, and dropping one later is a matter of not shipping it
rather than reconciling two hand-maintained copies.

    md2ipynb.py <src-dir> <dst-dir>

Every ``NN-name.md`` in src-dir whose prefix is in PAGES becomes
``NN-name.ipynb`` in dst-dir. Anything else is left alone -- the troubleshooting
page is a lookup table, not a walkthrough, and a notebook of it would only be a
worse way to read it.

Conversion rules
----------------
Prose becomes Markdown cells, split at headings so that no cell is a wall of
text. ```bash fences become code cells; every other fence stays inside the
Markdown cell it appeared in, because those are illustrations (a manifest, a
Dockerfile) rather than things to run.

Shell cells use the ``%%bash`` cell magic rather than ``!command`` per line.
That is not a style preference: the pages are full of heredocs, and a heredoc
cannot survive being split into ``!`` lines. The cost is that each cell is one
subshell, so shell variables and ``cd`` do not carry between cells -- which is
what the generated setup cell exists to fix. It sets the working directory and
the environment *in the kernel*, and every ``%%bash`` subprocess inherits both.

Fence directives
----------------
Extra words in the info string, e.g. ```bash notebook-skip. They are invisible
in rendered Markdown (renderers use the first word for highlighting and ignore
the rest), so one source serves both editions:

  notebook-skip        keep it as a fenced block in a Markdown cell instead of a
                       runnable cell. For commands that cannot work in a kernel:
                       an interactive shell, an endless loop, a reference list
                       full of <placeholders>.
  notebook-timeout=N   wrap the cell in `timeout N` so a watch command shows
                       what it is meant to show and then ends, instead of
                       hanging the kernel until someone interrupts it.
"""

import json
import os
import re
import sys

# prefix -> (working subdirectory relative to $CIRRUS_WORKDIR or None,
#            whether the page's commands need $IMG)
PAGES = {
    "01": (None, True),
    "02": ("k8s", True),
    "03": ("helm", True),
    "04": ("gitops", True),
    "05": (None, False),
}

FENCE = re.compile(r"^```([^\n]*)\n(.*?)^```[ \t]*$", re.S | re.M)
HEADING = re.compile(r"^(#{2,3})\s", re.M)


def md_cell(source):
    return {"cell_type": "markdown", "metadata": {}, "source": _lines(source)}


def code_cell(source):
    return {
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": _lines(source),
    }


def _lines(text):
    """nbformat wants a list of lines, each keeping its trailing newline."""
    text = text.strip("\n")
    if not text:
        return []
    lines = text.split("\n")
    return [l + "\n" for l in lines[:-1]] + [lines[-1]]


def split_prose(text):
    """One Markdown cell per heading section, so cells stay scrollable."""
    text = text.strip("\n")
    if not text:
        return []
    bounds = [m.start() for m in HEADING.finditer(text)]
    if not bounds:
        return [md_cell(text)]
    if bounds[0] != 0:
        bounds.insert(0, 0)
    bounds.append(len(text))
    out = []
    for a, b in zip(bounds, bounds[1:]):
        chunk = text[a:b].strip("\n")
        if chunk:
            out.append(md_cell(chunk))
    return out


def setup_cell(prefix, title):
    subdir, needs_img = PAGES[prefix]
    lines = [
        "# Setup for this notebook -- run this first.",
        "#",
        "# Each %%bash cell below is its own subshell, so a variable set in one",
        "# cell is gone in the next. Setting them here instead puts them in the",
        "# kernel's own environment and working directory, which every %%bash",
        "# subprocess inherits.",
        "import os, pathlib, subprocess",
        "",
        "workdir = pathlib.Path(os.environ.get('CIRRUS_WORKDIR',",
        "                                      pathlib.Path.home() / 'cirrus-workshop'))",
    ]
    if subdir:
        lines += [
            f"here = workdir / {subdir!r}",
            "here.mkdir(parents=True, exist_ok=True)",
            "os.chdir(here)",
            "print('working directory:', os.getcwd())",
        ]
    else:
        lines += [
            "os.chdir(workdir)",
            "print('working directory:', os.getcwd())",
        ]
    if needs_img:
        lines += [
            "",
            "# The image this session is running -- guaranteed pullable by this",
            "# cluster. The pages explain why that matters.",
            "#",
            "# Bounded, and this is the whole reason the timeout is here: with a",
            "# cold token cache kubectl starts a device-code sign-in, and that",
            "# prompt has nowhere to appear inside a kernel. Unbounded, this cell",
            "# -- the first cell of the notebook -- would simply hang.",
            "img = ''",
            "try:",
            "    img = subprocess.run(",
            "        ['kubectl', 'get', 'pod', os.uname().nodename,",
            "         '-o', 'jsonpath={.spec.containers[0].image}'],",
            "        capture_output=True, text=True, timeout=20).stdout.strip()",
            "except (subprocess.TimeoutExpired, FileNotFoundError):",
            "    pass",
            "",
            "if img:",
            "    os.environ['IMG'] = img",
            "    print('IMG =', img)",
            "else:",
            "    print('Could not read the image reference.')",
            "    print()",
            "    print('Run  kubectl get pods  in a TERMINAL, complete the device-code')",
            "    print('sign-in, then re-run this cell. A credential prompt cannot be')",
            "    print('shown inside a kernel, so it can only time out here.')",
        ]
    return code_cell("\n".join(lines))


PREAMBLE = """> **Notebook edition.** Generated from `{md}`, which is the same material to
> read rather than run. Three things to know before you start:
>
> 1. **Sign in from a terminal first.** Run `kubectl get pods` in a terminal and
>    complete the device-code prompt. A credential prompt has nowhere to appear
>    inside a kernel, so the first `kubectl` in a notebook will simply time out.
>    You will need to do this again roughly hourly, when the token expires.
> 2. **Run the setup cell below**, once. It sets the working directory and `$IMG`
>    in the kernel, which every `%%bash` cell inherits.
> 3. **A few steps are terminal-only** and appear as plain code blocks rather
>    than runnable cells -- an interactive shell, an endless reconcile loop, two
>    things watched at once. They are marked where they appear.
"""


def convert(src_path, dst_path):
    prefix = os.path.basename(src_path).split("-", 1)[0]
    text = open(src_path, encoding="utf-8").read()

    title = ""
    m = re.search(r"^#\s+(.*)$", text, re.M)
    if m:
        title = m.group(1)

    # Sibling links point at the notebook edition where one exists.
    def relink(mo):
        target = mo.group(1)
        pre = target.split("-", 1)[0]
        return f"]({target[:-3]}.ipynb)" if pre in PAGES else mo.group(0)

    text = re.sub(r"\]\((\d\d-[a-z0-9-]+\.md)\)", relink, text)

    cells = []
    pos = 0
    prose = []

    for mo in FENCE.finditer(text):
        info = mo.group(1).strip()
        body = mo.group(2)
        prose.append(text[pos:mo.start()])
        pos = mo.end()

        tokens = info.split()
        lang = tokens[0] if tokens else ""
        directives = tokens[1:]

        runnable = lang == "bash" and "notebook-skip" not in directives
        if not runnable:
            # Keep it where it was, minus our directives so the fence stays clean.
            prose.append(f"```{lang}\n{body}```\n")
            continue

        # Flush the prose accumulated before this cell.
        cells.extend(split_prose("".join(prose)))
        prose = []

        timeout = None
        for d in directives:
            if d.startswith("notebook-timeout="):
                timeout = d.split("=", 1)[1]

        if timeout:
            magic = f"%%bash\n# Bounded to {timeout}s so the cell ends on its own;\n# in a terminal you would watch this and press Ctrl-C.\ntimeout {timeout} bash <<'CIRRUS_CELL'\n{body}CIRRUS_CELL"
        else:
            magic = f"%%bash\n{body.rstrip()}"
        cells.append(code_cell(magic))

    prose.append(text[pos:])
    cells.extend(split_prose("".join(prose)))

    # Header: the page title, then the notebook-specific preamble, then setup.
    head = []
    if cells and cells[0]["cell_type"] == "markdown":
        head.append(cells.pop(0))
    head.append(md_cell(PREAMBLE.format(md=os.path.basename(src_path))))
    head.append(setup_cell(prefix, title))
    cells = head + cells

    nb = {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3 (CIRRUS)",
                "language": "python",
                "name": "python3",
            },
            "language_info": {"name": "python", "file_extension": ".py"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }
    with open(dst_path, "w", encoding="utf-8") as fh:
        json.dump(nb, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    return len(cells), sum(1 for c in cells if c["cell_type"] == "code")


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    os.makedirs(dst, exist_ok=True)
    made = 0
    for name in sorted(os.listdir(src)):
        if not name.endswith(".md"):
            continue
        if name.split("-", 1)[0] not in PAGES:
            continue
        out = os.path.join(dst, name[:-3] + ".ipynb")
        total, code = convert(os.path.join(src, name), out)
        print(f"{name} -> {os.path.basename(out)}  ({total} cells, {code} runnable)")
        made += 1
    if not made:
        sys.stderr.write(f"md2ipynb: no convertible pages in {src}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
