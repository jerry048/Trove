
# Universal Ren'Py Mod Installation Script

Universal Ren’Py Mod is a powerful tool that allows you to mod any Ren’Py game without any programming knowledge. However, its installation could prove to be tiresome if one is managing a huge catalogue of games. This Python script automates the installation of the Universal Ren'Py Mod (URM) onto your Ren'Py games by creating symbolic links. The script scans through your game directory, identifies games based on Ren'Py, and installs the URM.

## Pre-requisites

1.  Python installed on your machine.
2.  A copy of Universal Ren'Py Mod (URM). You can download from here [Universal Ren'Py Mod | 0x52](https://0x52.dev/mods/Universal-Ren-Py-Mod-1000) 

## How to Use

1.  Update the  `src_dir`  variable in the script with the full path to your Universal Ren'Py Mod (URM) file.
2.  Update the  `game_dir`  variable in the script with the full path to the directory containing all the Ren'Py games.
3.  Run the script.

```
python urm_install.py
```

## Notes

1.  The script creates a symbolic link to the URM instead of copying it to each game folder. This saves space and allows updates to the URM to be reflected in all games instantly.
2.  If the script encounters a game that has already been modded with an exact copy of the URM, it will replace the copy with a symbolic link to the URM.
3.  The script will skip any game folders that do not have the expected structure.

## Troubleshooting

1.  If the script cannot find the URM or the game directory, check that the paths are correct and that the files exist. Do not delete the original copy of the Universal Ren'Py Mod, as it is the only copy used by all the games
2.  If the script reports that a game folder is corrupted, check the folder structure of the game. It should have a  `game`  and a  `renpy`  folder in its root directory. If these are not present, the game may not be a Ren'Py game, or the game files may be corrupted.
3.  If the script is not creating symbolic links, ensure that you have the necessary permissions to create symbolic links in the game directory.

## Disclaimer

This script modifies game files. Always back up your game files before running the script. Use this script at your own risk.
