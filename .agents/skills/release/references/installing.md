# Installing The Repo-Tracked Skill

The source of truth for this skill is the repo copy:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release
```

The script directory lives inside the same skill:

```bash
/Users/zoncaesar/ws/appliance-release/.agents/skills/release/scripts
```

To expose it as a global Codex skill on this machine, point the global path at
the repo copy:

```bash
mv ~/.agents/skills/appliance-release ~/.agents/skills/appliance-release.backup
ln -s /Users/zoncaesar/ws/appliance-release/.agents/skills/release \
  ~/.agents/skills/appliance-release
```

If the global path is already a symlink, recreate it so it points at the repo
copy.

After that, Codex should keep discovering the skill through the normal global
skill path while the actual files stay versioned in the repo.
