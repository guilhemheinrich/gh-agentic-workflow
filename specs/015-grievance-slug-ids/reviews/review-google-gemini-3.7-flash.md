"
```
Line 208 is `if not path.is_file():`.
Line 213 is `text = path.read_text(encoding="utf-8")`.
Line 214 is the marker check for index markers.

Wait! What if git conflict markers are present in `GRIEVANCES.md`?
Suppose git creates a merge conflict in `specs/GRIEVANCES.md`.
Where does git place conflict markers?
Git might place `<<<<<<< HEAD` or `<<<<<<< feature-branch` or `<<<<<<< 015-slugs`!
Notice git's conflict marker format:
`<<<<<<< <branch_name>` (7 angle brackets followed by a space and branch name / commit)
`=======`
`>>>>>>> <branch_name>` (7 angle brackets followed by a space and branch name / commit)
Wait! What if git writes conflict markers around a diff?
`find_conflict_markers` looks for lines starting with `<<<<<<< ` or `>>>>>>> `.
Wait! What if there is `<<<<<<<` with no trailing space (e.g., EOF or just `<<<<<<<`)? Git always outputs `<<<<<<< ` followed by the branch/ref or `<<<<<<< HEAD`.
Wait, what if a user has `<<<<<<<` followed by a tab or newline in some tool? `re.match(r"^<{7}(?: |$)", ...)` or `line.startswith("<<<<<<< ")`.

Wait! Look at `Ledger.load` index markers check at line 214:
```python
        for marker in (OPEN_START, OPEN_END, RESOLVED_START, RESOLVED_END):
            if marker not in text:
                raise UserError(
                    f"{path}: missing index marker {marker}\n"
                    "this file predates the programmatic format — run: "
                    f"{Path(sys.argv[0]).name} migrate --from {path}"
                )
```
If `find_conflict_markers` is called AFTER `text = path.read_text(...)` (before the block parsing / index marker checking), then if a conflict marker corrupted `
