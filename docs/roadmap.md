# Roadmap

This is where the project is heading. Nothing here has a date, and the order can change as things turn out harder or easier than expected. If you'd like to help, the [Add a game tutorial](tutorials/add-a-game.md) is the quickest way in.

## Keep adding games to the database

The database covers only some of the games that used EAX. The plan is to keep adding games, and to move entries from `untested/` to `tested/` as people check them on real installs. A game that's in the database shows up in the library scan, and the install can set it up without guessing.

## Turn EAX on automatically for more games

When a game's entry lists the setting that switches EAX on, the install changes it for you. Some entries don't list one yet. For those games the install puts the files in place and leaves you to look for the option in the game's menu, if it has one. The plan is to add the missing settings, so the install can enable EAX in those games too.

## Better docs and tutorials

The wiki has two short tutorials, one for installing the fix and one for adding a game. The plan is to turn them into proper walkthroughs: one for using the script from the first run to a working game, and one for using the profile editor from an empty entry to a pull request. They should make sense to someone who has never opened the project before.

## A profile editor that runs on its own

The profile editor is a web page you start from a terminal inside a clone of the repository. The plan is to make it a standalone app you can download and run without cloning anything, so adding a game doesn't need a development setup.

## Move the script to Rust with a new interface

The script is a single Bash program that asks its questions in the terminal. In the long term, the plan is to replace it with a Rust program that has either a full-screen text interface or a graphical one. A first version of the text interface exists on the `dev` branch. It's unfinished and isn't part of a release, and for now it hands the real work to the Bash script.

Until the replacement is ready, the Bash script is the way to install the fix.
