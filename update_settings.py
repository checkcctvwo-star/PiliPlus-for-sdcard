import re

with open('lib/pages/setting/models/extra_settings.dart', 'r') as f:
    content = f.read()

with open('.scratch/sdcard-saf-storage-refactor/issues/replacement_code.dart', 'r') as f:
    replacement = f.read()

# Find the start of _showAndroidDownPathDialog
start_idx = content.find('void _showAndroidDownPathDialog(BuildContext context, VoidCallback setState) {')
if start_idx == -1:
    print("Could not find function")
    exit(1)

# Find the end of the function by counting braces
end_idx = start_idx
brace_count = 0
found_first_brace = False

while end_idx < len(content):
    if content[end_idx] == '{':
        brace_count += 1
        found_first_brace = True
    elif content[end_idx] == '}':
        brace_count -= 1
        
    if found_first_brace and brace_count == 0:
        break
        
    end_idx += 1

if not (found_first_brace and brace_count == 0):
    print("Could not find end of function")
    exit(1)

new_content = content[:start_idx] + replacement + content[end_idx + 1:]

with open('lib/pages/setting/models/extra_settings.dart', 'w') as f:
    f.write(new_content)

print("Successfully updated extra_settings.dart")
