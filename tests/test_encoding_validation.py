#!/usr/bin/env python3
"""Test encoding validation functionality"""

import subprocess
import sys
import os

# Add project root to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VX = os.path.join(REPO_ROOT, "zig-out", "bin", "vx")

def test_validation_command():
    """Test that VX properly validates encoding"""
    print("🧪 Testing VX encoding validation:\n")

    # Test 1: Safe content should work
    print("1. Testing safe ASCII content...")
    result = subprocess.run(
        [VX, '--version'],
        capture_output=True,
        timeout=5
    )
    print(f"   VX binary exists: {result.returncode == 0}\n")

    # Test 2: Create test file with mixed content
    import tempfile

    print("2. Creating test files with problematic content...")

    # File 1: Russian + Chinese (problematic for CP1251)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as f:
        f.write("Привет! 世界!\n")
        file_ru_cn = f.name

    # File 2: Safe Russian only (OK for CP1251)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as f:
        f.write("Привет мир!\n")
        file_ru_only = f.name

    # File 3: Safe ASCII (OK for everything)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as f:
        f.write("Hello World!\n")
        file_ascii = f.name

    print(f"   Created test files:\n")
    print(f"     - {file_ru_cn}: Russian + Chinese")
    print(f"     - {file_ru_only}: Russian only")
    print(f"     - {file_ascii}: ASCII only\n")

    # Test 3: Try to read files with different encodings
    print("3. Testing file reading with validation...")

    test_cases = [
        (file_ascii, "ascii", True, "ASCII should work everywhere"),
        (file_ru_only, "cp1251", True, "Russian-only should work in CP1251"),
        (file_ru_cn, "cp1251", False, "Mixed content should be rejected for CP1251"),
    ]

    for file_path, enc, should_succeed, description in test_cases:
        print(f"\n   Testing: {description}")
        print(f"   File: {os.path.basename(file_path)}")
        print(f"   Encoding: {enc}")

        # Try to get file info (metadata)
        result = subprocess.run(
            [VX, '--file-info', file_path],
            capture_output=True,
            timeout=5
        )

        if should_succeed:
            if result.returncode == 0:
                print(f"   ✅ PASS: File opened successfully")
            else:
                print(f"   ❌ FAIL: Should have opened but got error")
                print(f"   stderr: {result.stderr.decode('utf-8', errors='replace')}")
        else:
            if result.returncode != 0:
                print(f"   ✅ PASS: Correctly rejected")
                if "cannot be represented" in result.stderr.decode('utf-8', errors='replace'):
                    print(f"   ✅ Clear error message provided")
                else:
                    print(f"   ⚠️  Error message: {result.stderr.decode('utf-8', errors='replace')[:100]}")
            else:
                print(f"   ❌ FAIL: Should have rejected but was accepted")

    # Cleanup
    print("\n4. Cleaning up test files...")
    for path in [file_ru_cn, file_ru_only, file_ascii]:
        try:
            os.unlink(path)
            print(f"   Removed: {os.path.basename(path)}")
        except:
            pass

if __name__ == "__main__":
    test_validation_command()
    print("\n✅ Validation tests completed")