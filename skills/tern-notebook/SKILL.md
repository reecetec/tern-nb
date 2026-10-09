---
name: tern-notebook
description: Read, edit and run cells of Jupyter notebooks open in Tern, in their live kernel, via the tern-nb CLI. Use when the user mentions a notebook open in Tern, wants code run in "the notebook's kernel", or wants notebook cells inspected or changed.
---

# Tern notebooks

`tern-nb` drives notebook blocks open in Tern, through the `nbbridge` Tern plugin (`~/code/tern-nb`, github.com/reecetec/tern-nb). Code runs in the notebook's own live kernel, so variables the user defined are there, and every cell you add or run shows up in their notebook.

```sh
tern-nb list                          # open notebooks (pane id, path, kernel); * = focused
tern-nb open path/to/analysis.ipynb   # open beside the focused pane; prints the pane id
tern-nb cells [--no-outputs]          # every cell: id, kind, In[n], state, source, outputs
tern-nb exec 'df.describe()'          # append a code cell, run it, print its outputs
tern-nb exec < script.py              # source from stdin (also: exec -)
tern-nb run 12                        # run an existing cell by id
tern-nb run --all                     # run every cell
tern-nb add --kind markdown '## Notes' --after 3
tern-nb edit 12 'new source'          # replace source (outputs kept); then `run 12`
tern-nb kernel                        # interpreter, status, running/waiting counts
tern-nb restart                       # restart without confirmation
tern-nb delete 12 [13 ...]            # delete cells (undoable)
tern-nb move 12 up|down [--by N]      # reorder a cell
tern-nb kind 12 code|markdown|raw     # change a cell's kind
tern-nb save                          # write the .ipynb to disk (then `git diff` it)
tern-nb interrupt                     # stop the running cell (KeyboardInterrupt)
tern-nb undo / redo                   # the notebook's own cell-edit undo
```

- With several notebooks open, pass `--nb PATH_OR_PANE` (before the subcommand, like `--timeout` and `--json`). With one open, it is the default.
- Cell ids are the stable numbers `cells` prints (`── cell 12`), not positions. `--after 0` inserts first.
- `exec`/`run` exit 1 when a cell raised (traceback printed), 2 when the bridge failed. Image outputs are saved to `$TMPDIR/tern-nb/` and printed as paths: `read` them to see plots.
- Runs wait without limit; add `--timeout S` for code that may hang. A timeout leaves the cell running; `kernel` shows `running`.
- `--json` prints the raw answer (full MIME bundles) when you need data other than text and images.
- `exec` leaves its cell in the user's notebook. For throwaway inspection that should not clutter the notebook, prefer reading with `cells`; ask before restarting the kernel (it drops all of the user's state).
- `delete`, `move`, `kind`, `save`, `interrupt`, `undo` and `redo` drive the notebook block's own key actions: they briefly focus the notebook (selecting the cell first) and give focus back. Each checks its result (the cell is gone, moved, re-kinded; nothing is left unsaved) and exits 2 if it didn't happen.
- Nothing reaches disk until `save`. Save when the user wants the change in git; a notebook committed with outputs then shows its new cells and changed outputs in `git diff`.
- If it reports the plugin isn't listening: Tern must be open and `tern plugin list` must show `nbbridge ready`.

## Setup

From a clone of github.com/reecetec/tern-nb:

```sh
tern plugin link /path/to/tern-nb                          # the nbbridge window plugin
ln -s /path/to/tern-nb/tern-nb ~/.local/bin/tern-nb        # the CLI (any directory on PATH)
ln -s /path/to/tern-nb/skills/tern-notebook ~/.agents/skills/tern-notebook   # this skill
```

Or install the skill alone with `npx skills add reecetec/tern-nb`.
