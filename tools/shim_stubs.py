"""Emit logging function stubs without redeclaring platform C identifiers."""
import hashlib
import json


def function_stub(symbol):
    """Keep the imported Mach-O name while using a private C identifier.

    A missing import can still be a Clang builtin or an SDK declaration,
    whose real prototype conflicts with a generated generic logging stub.
    An explicit assembler label preserves its export without that conflict.
    """
    identifier = 'AKGeneratedStub_' + hashlib.sha256(symbol.encode()).hexdigest()
    exported = json.dumps(symbol)
    name = json.dumps(symbol[1:])
    return (f'long {identifier}(void) __asm__({exported});\n'
            f'long {identifier}(void) {{ static char hit; if (!hit) {{ hit = 1; '
            f'AKStubHit({name}, __builtin_return_address(0)); }} return 0; }}')
