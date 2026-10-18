# assets/

## The printables

| File | What it is |
|---|---|
| `grid_sheet_3x4.svg` | The grid sheet: landscape Letter, 3 rows x 4 cols of 57.15 mm cells. No tags on it. |
| `mat_tags.svg` | The four AprilTags, to cut out and tape to the mat. |
| `workspace_sheet.json` | The geometry both of the above describe. **Everything in `robot/` reads this.** |
| `Apprentice_AprilTag_Grid.pdf` | The old sheet: portrait Letter, tags on the paper, 3x3 grid. Superseded. |

Regenerate all three with:

```bash
python -m robot.scripts.make_sheet                      # 3x4 landscape Letter (the default)
python -m robot.scripts.make_sheet --rows 3 --cols 7 --paper 2xletter
python -m robot.scripts.tests.check_printables          # tags decode? spec consistent?
```

## Why the tags moved off the sheet

The old sheet spent two bands of paper on tags, which left room for only a 3x3 grid. Tags do
not have to be on the paper: they only have to be somewhere the camera sees, at positions the
spec knows. Moving them to the mat frees the whole sheet, and turning it landscape fits a
wider grid:

```
portrait Letter,  tags on the sheet:   3 x 3 =  9 cells
landscape Letter, tags on the mat:     3 x 4 = 12 cells
```

**4 x 3 is the ceiling at this cell size.** Five columns would need 285.8 mm across a 279.4 mm
page; four rows would need 228.6 mm down a 215.9 mm page. The arm is not the limit here - its
envelope (radius 60-340 mm from the pan axis, bearing +/-75 degrees) would reach a 3 x 7 grid,
so for a bigger play area print two sheets side by side rather than trying to squeeze the one.

## Putting it together

Each tag's inner corner butts against a corner of the grid sheet, so **the sheet is its own
alignment jig and there is nothing to measure**. Tape the tags to the mat first, then lay the
sheet inside them. Keep every tag upright as printed: `cv2.aruco.detectMarkers` returns
corners in the marker's own top-left, top-right, bottom-right, bottom-left order, and the spec
pairs with them index for index, so a rotated tag puts a 90-degree error straight into the
homography.

Because the tags sit outside the paper, their spec coordinates are negative or past the
sheet's width and height. That is expected: the sheet frame still has its origin at the
sheet's top-left corner.

**Check the scale bar with a ruler after printing.** It must measure exactly 50.8 mm. A printer
left on "fit to page" shrinks everything a few percent, and every position in this project
would then be wrong by that factor, with nothing to indicate why.

## After re-making the sheet

The fitted calibration describes where things physically were, so it does not survive a new
sheet:

```bash
python -m robot.scripts.tests.scene_snapshot                 # are all 4 tags seen?
python -m robot.scripts.calibration.touch_calibrate --full   # refit sheet_to_base and offsets
python -m robot.scripts.calibration.auto_calibrate           # refit the placement correction
```

See [`../calibration/README.md`](../calibration/README.md) for which fitted numbers survive a
move and which do not.
