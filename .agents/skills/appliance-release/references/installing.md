# Installing The Repo-Tracked Skill

The source of truth for this skill is the repo copy:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/appliance-release
```

The canonical script directory is:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/scripts
```

The path `/Users/zoncaesar/ws/appliance-release/.agents/skills/appliance-release/scripts`
is kept only as a compatibility symlink.

To expose it as a global Codex skill on this machine, point the global path at
the repo copy:

```bash
mv ~/.agents/skills/appliance-release ~/.agents/skills/appliance-release.backup
ln -s /Users/zoncaesar/ws/appliance-release/.agents/skills/appliance-release \
  ~/.agents/skills/appliance-release
```

If the global path is already a symlink, recreate it so it points at the repo
copy.

After that, Codex should keep discovering the skill through the normal global
skill path while the actual files stay versioned in the repo.
