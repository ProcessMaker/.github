This folder contains templates that get synced to repositories listed in repositories.txt. That file has one repo per line and corresponds to `https://github.com/ProcessMaker/<repo>`

To sync these, run the "Sync Workflow Templates" action at https://github.com/ProcessMaker/.github/actions

The github action will iterate over all *.yml files in this folder. If the file already exists in the target repository, it will be updated. If not, it will be created.

To make changes to these workflows:
- Add repositories to repositories.txt
- Add or update your workflow in this folder
- Commit the changes
- Go to https://github.com/ProcessMaker/.github/actions and run the "Sync Workflow Templates" action