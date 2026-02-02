"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Generate Directory Index HTML files for Phantom-WG Test Reports
Creates clean, navigable directory listings for test reports

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import os
import sys
import logging
from pathlib import Path
from datetime import datetime
import html

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(levelname)-8s %(message)s'
)


def format_size(size):
    """Format file size in human readable format"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} TB"


def create_index_html(directory_path, root_path=None):
    """Create an index.html file for a directory"""

    directory = Path(directory_path)
    if root_path:
        root = Path(root_path)
        relative_path = directory.relative_to(root)
    else:
        relative_path = Path()

    # Get directory contents
    items = []
    for item in sorted(directory.iterdir()):
        # Skip hidden files and index.html itself
        if item.name.startswith('.') or item.name == 'index.html':
            continue

        stat = item.stat()

        if item.is_dir():
            items.append({
                'name': item.name,
                'is_dir': True,
                'modified': datetime.fromtimestamp(stat.st_mtime),
                'size': None
            })
        else:
            items.append({
                'name': item.name,
                'is_dir': False,
                'modified': datetime.fromtimestamp(stat.st_mtime),
                'size': stat.st_size
            })

    # Build breadcrumb
    breadcrumb_parts = []
    if relative_path != Path():
        current = Path()
        breadcrumb_parts.append(('Test Reports', '../' * len(relative_path.parts)))
        for part in relative_path.parts:
            current = current / part
            depth = len(relative_path.parts) - len(current.parts)
            breadcrumb_parts.append((part, '../' * depth if depth > 0 else './'))
    else:
        breadcrumb_parts.append(('Test Reports', './'))

    # Generate HTML
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Phantom-WG Test Reports - {relative_path or 'Home'}</title>

    <link href="https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@600&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" integrity="sha512-DTOQO9RWCH3ppGqcWaEA1BIZOC6xxalwEsw9c2QQeAIftl+Vegovlnee1c9QX4TctnWMn13TZye+giMm8e2LwA==" crossorigin="anonymous" referrerpolicy="no-referrer" />

    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}

        body {{
            font-family: 'Share Tech Mono', monospace;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            color: #e8eaed;
            padding: 20px;
        }}

        .container {{
            max-width: 1200px;
            margin: 0 auto;
            background: rgba(15, 24, 35, 0.95);
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
            border: 1px solid rgba(74, 158, 255, 0.2);
        }}

        .header {{
            background: linear-gradient(135deg, #0f1419 0%, #1a2332 100%);
            padding: 30px;
            border-bottom: 2px solid #4a9eff;
        }}

        h1 {{
            font-family: 'Orbitron', monospace;
            font-size: 28px;
            color: #4a9eff;
            margin-bottom: 15px;
            text-shadow: 0 0 10px rgba(74, 158, 255, 0.5);
        }}

        .breadcrumb {{
            font-size: 14px;
            color: #9aa0a6;
        }}

        .breadcrumb a {{
            color: #4a9eff;
            text-decoration: none;
            transition: color 0.3s;
        }}

        .breadcrumb a:hover {{
            color: #74b3ff;
            text-decoration: underline;
        }}

        .breadcrumb span {{
            margin: 0 8px;
            color: #495057;
        }}

        .content {{
            padding: 20px 30px 30px;
        }}

        .stats {{
            background: rgba(26, 35, 50, 0.5);
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 20px;
            border: 1px solid rgba(74, 158, 255, 0.1);
            font-size: 14px;
            color: #9aa0a6;
        }}

        .table-wrapper {{
            overflow-x: auto;
            -webkit-overflow-scrolling: touch;
            border-radius: 8px;
            background: rgba(26, 35, 50, 0.2);
        }}

        /* Custom scrollbar styles */
        .table-wrapper::-webkit-scrollbar {{
            height: 8px;
            background: rgba(26, 35, 50, 0.3);
        }}

        .table-wrapper::-webkit-scrollbar-track {{
            background: rgba(15, 24, 35, 0.5);
            border-radius: 4px;
        }}

        .table-wrapper::-webkit-scrollbar-thumb {{
            background: rgba(74, 158, 255, 0.3);
            border-radius: 4px;
            transition: background 0.3s;
        }}

        .table-wrapper::-webkit-scrollbar-thumb:hover {{
            background: rgba(74, 158, 255, 0.5);
        }}

        /* Firefox scrollbar */
        .table-wrapper {{
            scrollbar-width: thin;
            scrollbar-color: rgba(74, 158, 255, 0.3) rgba(15, 24, 35, 0.5);
        }}

        table {{
            width: 100%;
            min-width: 500px;
            border-collapse: collapse;
        }}

        thead {{
            background: rgba(26, 35, 50, 0.3);
            border-bottom: 2px solid rgba(74, 158, 255, 0.2);
        }}


        th {{
            text-align: left;
            padding: 12px;
            font-weight: 600;
            color: #4a9eff;
            font-size: 14px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }}

        td {{
            padding: 10px 12px;
            border-bottom: 1px solid rgba(57, 75, 97, 0.3);
            font-size: 14px;
        }}

        tr:hover {{
            background: rgba(74, 158, 255, 0.05);
        }}

        .icon {{
            display: inline-block;
            width: 20px;
            margin-right: 8px;
            text-align: center;
        }}

        .dir-icon {{
            color: #fbbc04;
        }}

        .file-icon {{
            color: #34a853;
        }}


        a {{
            color: #e8eaed;
            text-decoration: none;
            transition: color 0.3s;
        }}

        a:hover {{
            color: #4a9eff;
        }}


        .size {{
            color: #9aa0a6;
            font-size: 13px;
        }}

        .date {{
            color: #9aa0a6;
            font-size: 13px;
        }}

        .empty {{
            text-align: center;
            padding: 40px;
            color: #9aa0a6;
            font-style: italic;
        }}

        .footer {{
            background: linear-gradient(135deg, #0f1419 0%, #1a2332 100%);
            padding: 20px 30px;
            border-top: 2px solid rgba(74, 158, 255, 0.2);
            margin-top: 30px;
        }}

        .footer-content {{
            text-align: center;
            font-size: 13px;
            color: #9aa0a6;
        }}

        .footer-content p {{
            margin: 5px 0;
        }}

        .footer-content a {{
            color: #4a9eff;
            text-decoration: none;
            transition: color 0.3s;
        }}

        .footer-content a:hover {{
            color: #74b3ff;
            text-decoration: underline;
        }}

        .footer-tech {{
            font-size: 11px;
            color: #6c757d;
            margin-top: 8px;
        }}

        @media (max-width: 768px) {{
            .container {{
                border-radius: 0;
                margin: 0;
            }}

            body {{
                padding: 0;
            }}

            .header {{
                padding: 20px;
            }}

            h1 {{
                font-size: 22px;
            }}

            .breadcrumb {{
                font-size: 12px;
                word-break: break-word;
            }}

            .content {{
                padding: 15px;
            }}

            .stats {{
                font-size: 12px;
                padding: 12px;
            }}

            table {{
                font-size: 13px;
            }}

            th, td {{
                padding: 8px;
            }}

            .size-col {{
                display: none;
            }}

            .footer {{
                padding: 15px;
            }}

            .footer-content {{
                font-size: 11px;
            }}

            .footer-tech {{
                font-size: 10px;
            }}

        }}

        @media (max-width: 480px) {{
            h1 {{
                font-size: 18px;
            }}

            .breadcrumb {{
                font-size: 11px;
            }}

            .stats {{
                font-size: 11px;
            }}

            table {{
                font-size: 12px;
            }}

            th, td {{
                padding: 6px;
            }}

            .icon {{
                width: 16px;
                margin-right: 6px;
            }}

            .date {{
                font-size: 11px;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1><i class="fas fa-chart-bar"></i> Phantom-WG Test Reports</h1>
            <div class="breadcrumb">
                {' <span>/</span> '.join(f'<a href="{path}">{html.escape(name)}</a>' for name, path in breadcrumb_parts)}
            </div>
        </div>

        <div class="content">
            <div class="stats">
                <i class="fas fa-folder"></i> {sum(1 for i in items if i['is_dir'])} directories,
                <i class="fas fa-file"></i> {sum(1 for i in items if not i['is_dir'])} files
            </div>

            {generate_table(items) if items else '<div class="empty">No files or directories found</div>'}
        </div>

        <div class="footer">
            <div class="footer-content">
                <p>Copyright (c) 2025 Rıza Emre ARAS</p>
                <p class="footer-tech">WireGuard® is a registered trademark of Jason A. Donenfeld</p>
            </div>
        </div>
    </div>
</body>
</html>"""

    return html_content


def generate_table(items):
    """Generate the file listing table"""
    rows = []

    # Directories first, then files
    sorted_items = sorted(items, key=lambda x: (not x['is_dir'], x['name'].lower()))

    for item in sorted_items:
        if item['is_dir']:
            # Regular directory
            link = f"{item['name']}/index.html"
            icon = '<i class="fas fa-folder icon dir-icon"></i>'
            name_display = f'<a href="{link}">{html.escape(item["name"])}/</a>'
        else:
            # Regular file
            link = item['name']
            icon = '<i class="fas fa-file-alt icon file-icon"></i>'
            name_display = f'<a href="{link}">{html.escape(item["name"])}</a>'

        size_display = f'<td class="size size-col">{format_size(item["size"])}</td>' if item[
            'size'] else '<td class="size size-col">-</td>'
        date_display = f'<td class="date">{item["modified"].strftime("%Y-%m-%d %H:%M")}</td>'

        rows.append(f"""
            <tr>
                <td>{icon}{name_display}</td>
                {size_display}
                {date_display}
            </tr>
        """)

    return f"""
        <div class="table-wrapper">
            <table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th class="size-col">Size</th>
                        <th>Modified</th>
                    </tr>
                </thead>
                <tbody>
                    {''.join(rows)}
                </tbody>
            </table>
        </div>
    """


def process_directory_tree(root_dir):
    """Process entire directory tree and create index files"""
    root = Path(root_dir)

    if not root.exists():
        logging.error(f"Directory {root} does not exist")
        return False

    processed = 0
    skipped = 0

    # Walk through directory tree
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip hidden directories and htmlcov directories
        dirnames[:] = [d for d in dirnames if not d.startswith('.') and d != 'htmlcov']

        current_dir = Path(dirpath)

        # Skip if this is an htmlcov directory
        if current_dir.name == 'htmlcov':
            logging.debug(f"Skipping htmlcov directory: {current_dir}")
            skipped += 1
            continue

        # Create index.html for this directory
        html_content = create_index_html(current_dir, root)
        index_path = current_dir / "index.html"

        with open(index_path, 'w', encoding='utf-8') as f:
            f.write(html_content)

        logging.info(f"Created: {index_path.relative_to(root.parent)}")
        processed += 1

    logging.info(f"Successfully created {processed} index files (skipped {skipped} htmlcov directories)")
    return True


def main():
    """Main entry point"""
    if len(sys.argv) < 2:
        logging.error("Usage: python generate_directory_indexes.py <directory>")
        logging.error("Example: python generate_directory_indexes.py ../../phantom/reports/SESSION_ID")
        sys.exit(1)

    target_dir = sys.argv[1]

    logging.info(f"Generating directory indexes for: {target_dir}")
    logging.info("=" * 50)

    success = process_directory_tree(target_dir)

    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
