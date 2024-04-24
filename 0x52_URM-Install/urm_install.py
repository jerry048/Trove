import os
from glob import glob

# Path of the Universal Ren'Py Mod. Please Change this to your path
src_dir = "D:\\Games\\0x52_URM.rpa"

if not os.path.isfile(src_dir):
    print("Error: Universal Ren'Py Mod not found")
    exit(1)

# Directory of the game folder. Please Change this to your path
game_dir = "D:\\Games"

if not os.path.isdir(game_dir):
    print("Error: Game directory not found")
    exit(1)


skip = 0
modded = 0
not_renpy = 0

game_list = glob(game_dir + "\\*\\", recursive=True)
for x in game_list:
    game_name = x.split("\\")[-2]
    dst_dir = x + "game\\0x52_URM.rpa"

    # Check if the game is based on Ren'Py
    if os.path.isdir(x + "renpy"):
        pass
    else:
        not_renpy += 1
        continue

    # Check if the game folder structure is corrupted
    if not os.path.isdir(x + "game"):
        print("Error: Game folder corrupted for " + game_name)
        skip += 1
        continue

    # Installing the mod if the game is not modded
    if os.path.islink(dst_dir):
        skip += 1
    elif os.path.isfile(dst_dir):
        os.remove(dst_dir)
        print("Exact mod copy removed for " + game_name)
        os.symlink(src_dir, dst_dir)
        print("Symlink created for " + game_name)
        modded += 1
    else:
        os.symlink(src_dir, dst_dir)
        print("Symlink created for " + game_name)
        modded += 1
print("Total games found: " + str(len(game_list)))
print("Total games modded: " + str(modded))
print("Total games skipped: " + str(skip))
print("Total non Ren'Py games: " + str(not_renpy))
