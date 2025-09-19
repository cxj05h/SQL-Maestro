#!/bin/bash

echo "🔄 Updating ReleaseAssets with current data..."

SANDBOX_PATH="$HOME/Library/Containers/Flexera.SQLMaestro/Data/Library/Application Support/SQLMaestro"
RELEASE_ASSETS_PATH="./SQLMaestro/ReleaseAssets"  # ✅ ONLY CHANGE: Fixed path

# Check if sandbox data exists
if [ ! -d "$SANDBOX_PATH" ]; then
    echo "❌ Sandbox data not found at: $SANDBOX_PATH"
    exit 1
fi

# Remove old ReleaseAssets
rm -rf "$RELEASE_ASSETS_PATH"
mkdir -p "$RELEASE_ASSETS_PATH"/{templates,mappings}

# Copy only demo templates (as specified)
echo "📋 Copying demo templates..."
find "$SANDBOX_PATH/templates" -name "*demo*" -type f -exec cp {} "$RELEASE_ASSETS_PATH/templates/" \;

# Copy all mappings, excluding backups AND user_config.json for security
echo "🗺️ Copying mappings..."
rsync -av --exclude='*.backup' --exclude='user_config.json' "$SANDBOX_PATH/mappings/" "$RELEASE_ASSETS_PATH/mappings/"  # ✅ ADDED: --exclude='user_config.json'

# Clear sensitive mappings (leave editable skeletons)
echo "🗑️ Creating empty org/mysql mapping skeletons..."
cat > "$RELEASE_ASSETS_PATH/mappings/org_mysql_map.json" << 'EOFORG'
{
  "companies": {}
}
EOFORG

cat > "$RELEASE_ASSETS_PATH/mappings/mysql_host_map.json" << 'EOFHOST'
{
  "hosts": {}
}
EOFHOST

# Copy root files
echo "📊 Copying root files..."
cp "$SANDBOX_PATH/db_tables_catalog.json" "$RELEASE_ASSETS_PATH/" 2>/dev/null || echo "No db_tables_catalog.json"
cp "$SANDBOX_PATH/placeholders.json" "$RELEASE_ASSETS_PATH/" 2>/dev/null || echo "No placeholders.json"
cp "$SANDBOX_PATH/placeholder_order.json" "$RELEASE_ASSETS_PATH/" 2>/dev/null || echo "No placeholder_order.json"

# Clear credentials (keep feature available)
echo "🔒 Clearing credentials..."
cat > "$RELEASE_ASSETS_PATH/mappings/user_config.json" << 'EOFCONFIG'
{
  "mysql_username": "",
  "mysql_password": "",
  "querious_path": "/Applications/Querious.app"
}
EOFCONFIG

# ✅ ADDED: Verification
echo "🔍 Verifying credentials are cleared..."
if grep -q '""' "$RELEASE_ASSETS_PATH/mappings/user_config.json"; then
    echo "✅ Credentials successfully cleared"
else
    echo "❌ WARNING: Credentials may not be cleared!"
    cat "$RELEASE_ASSETS_PATH/mappings/user_config.json"
    exit 1
fi

echo "✅ ReleaseAssets updated successfully!"
echo "📊 Summary:"
echo "Templates: $(ls -1 "$RELEASE_ASSETS_PATH/templates/" | wc -l | tr -d ' ')"
echo "Mappings: $(ls -1 "$RELEASE_ASSETS_PATH/mappings/" | wc -l | tr -d ' ')"
echo "Root files: $(ls -1 "$RELEASE_ASSETS_PATH"/*.json 2>/dev/null | wc -l | tr -d ' ')"