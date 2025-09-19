# Install 
```
brew tap cxj05h/tap
brew install --cask sql-maestro
```

# Upgrade
`brew upgrade --cask sql-maestro`

# Uninstall
```
brew uninstall --cask sql-maestro
brew cleanup --prune=all
brew doctor
```

# Allow macOS to run the unsigned app
```
sudo xattr -rd com.apple.quarantine "/Applications/SQLMaestro.app"
```
