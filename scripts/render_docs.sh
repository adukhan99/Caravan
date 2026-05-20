#!/bin/bash
set -e

# This script finds all .md files, renders mermaid diagrams to .svg files,
# renames them to match the .rendered.svg pattern (ignored by git),
# and updates the markdown files to link to the rendered images.

# Ensure mmdc is available
if ! command -v mmdc &> /dev/null; then
    echo "mmdc could not be found. Please install @mermaid-js/mermaid-cli."
    exit 1
fi

# Process all .md files in docs/ and the root directory
# We look in docs/ and the current directory (for README.md)
find docs . -maxdepth 1 -name "*.md" -not -path "./_build/*" | while read -r file; do
    if grep -q '```mermaid' "$file"; then
        echo "Processing $file..."
        
        # Use mmdc to render. mmdc will replace the blocks and create -1.svg, -2.svg, etc.
        mmdc -i "$file" -o "$file"
        
        # Get the base name without extension
        base_path="${file%.md}"
        
        # Find all generated SVGs (e.g., docs/architecture-1.svg)
        # Note: mmdc uses a hyphen and a number
        # We use a glob to find them
        for svg in ${base_path}-*.svg; do
            # Check if any files were found
            [ -e "$svg" ] || continue
            
            # Transform e.g. architecture-1.svg to architecture.rendered-1.svg
            # This matches the docs/*.rendered* pattern in .gitignore
            # We replace the last hyphen with .rendered-
            new_svg=$(echo "$svg" | sed 's/-\([0-9]\+\)\.svg$/.rendered-\1.svg/')
            
            echo "Renaming $svg to $new_svg"
            mv "$svg" "$new_svg"
            
            # Update the link in the markdown file
            svg_base=$(basename "$svg")
            new_svg_base=$(basename "$new_svg")
            
            # Update links in the .md file
            sed -i "s|$svg_base|$new_svg_base|g" "$file"
        done
    fi
done
