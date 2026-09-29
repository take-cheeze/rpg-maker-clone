#!/usr/bin/env python3
"""Extract the facts scripts/native_binding_split.rb classifies (ADR 0263).

For every mrb_define_method / mrb_define_class_method /
mrb_define_module_function registration in a translation unit of
mruby-rgss/src, print (JSON) where the bound function lives, its parameters,
its top-level statements, its mrb_get_args call and every reason its body can
read the calling frame.  This script only reports what clang sees; deciding
what is splittable, rewriting and generating the compiler table are the Ruby
script's job.

The gem is compiled by mruby's rake build, so CMake's
CMAKE_EXPORT_COMPILE_COMMANDS does not describe it.  The flags therefore come
from `--compile-commands FILE` when given, else from the repository layout
(the include paths of mruby-rgss/mrbgem.rake) plus the host compiler's own
system include directories.  `--emit-compile-commands FILE` writes the
derived database.

Needs libclang's Python bindings (`clang.cindex`): `nix develop .#clang`, or
LIBCLANG_PYTHONPATH / LIBCLANG_FILE pointing at an installation.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

CONFIG_DEFINES = {
    'host': [],
    'wio': ['-DWIO_TERMINAL'],
    'psp': ['-DPSP_BUILD'],
    'maix': ['-DMAIX_BUILD'],
    'emscripten': ['-D__EMSCRIPTEN__'],
}

REGISTRATION_APIS = {
    'mrb_define_method': 'method',
    'mrb_define_class_method': 'class_method',
    'mrb_define_module_function': 'module_function',
}

# Calls that read the calling frame: the arguments (get_args/argc/argv/arg1),
# the block, the method id, the C function's proc environment, super.
FRAME_READERS = {
    'mrb_get_args': 'get_args',
    'mrb_get_argc': 'get_argc',
    'mrb_get_argv': 'get_argv',
    'mrb_get_arg1': 'get_arg1',
    'mrb_block_given_p': 'block_given',
    'mrb_get_mid': 'get_mid',
    'mrb_yield': 'yield',
    'mrb_yield_argv': 'yield',
    'mrb_yield_with_class': 'yield',
    'mrb_yield_cont': 'yield',
    'mrb_proc_cfunc_env_get': 'cfunc_env',
    'mrb_call_super': 'super',
    'mrb_super_class': 'super',
    'mrb_get_backtrace': 'backtrace',
    'mrb_vm_ci_target_class': 'frame_api',
    'mrb_vm_ci_env': 'frame_api',
    'mrb_proc_env_get': 'frame_api',
    'mrb_obj_call_init': 'frame_api',
}

# mrb_state-taking functions from mruby's headers reviewed as not depending on
# the calling frame.  Anything else that takes an mrb_state (and is not a
# FRAME_READERS entry) is refused: fail closed, extend this list after review.
MRB_API_ALLOW = {
    'mrb_ary_new', 'mrb_ary_new_capa', 'mrb_ary_new_from_values', 'mrb_ary_push', 'mrb_ary_ref', 'mrb_ary_entry',
    'mrb_ary_set', 'mrb_ary_shift', 'mrb_ary_pop', 'mrb_ary_clear', 'mrb_ary_concat',
    'mrb_boxing_int_value', 'mrb_word_boxing_float_value', 'mrb_word_boxing_cptr_value', 'mrb_float_value',
    'mrb_int_value', 'mrb_fixnum_value',
    'mrb_class_get', 'mrb_class_get_under', 'mrb_module_get', 'mrb_module_get_under',
    'mrb_const_defined', 'mrb_const_get', 'mrb_const_set',
    'mrb_data_get_ptr', 'mrb_data_check_get_ptr', 'mrb_data_object_alloc', 'mrb_data_init',
    'mrb_ensure_float_type', 'mrb_ensure_int_type', 'mrb_ensure_string_type', 'mrb_check_type',
    'mrb_format', 'mrb_free', 'mrb_malloc', 'mrb_realloc', 'mrb_calloc',
    'mrb_funcall', 'mrb_funcall_argv', 'mrb_funcall_id',
    'mrb_gc_type_counts', 'mrb_gc_arena_save', 'mrb_gc_arena_restore', 'mrb_gc_protect',
    'mrb_hash_get', 'mrb_hash_set', 'mrb_hash_keys', 'mrb_hash_new', 'mrb_hash_size', 'mrb_hash_key_p',
    'mrb_hash_delete_key',
    'mrb_intern_cstr', 'mrb_intern_static', 'mrb_intern', 'mrb_intern_str', 'mrb_sym_name', 'mrb_sym_str',
    'mrb_iv_get', 'mrb_iv_set', 'mrb_iv_defined',
    'mrb_obj_as_string', 'mrb_obj_class', 'mrb_obj_classname', 'mrb_obj_equal', 'mrb_obj_is_kind_of',
    'mrb_obj_new', 'mrb_obj_value',
    'mrb_raise', 'mrb_raisef', 'mrb_exc_get_id',
    'mrb_str_new', 'mrb_str_new_cstr', 'mrb_str_new_static', 'mrb_str_to_cstr', 'mrb_string_value_cstr',
    'mrb_string_value_len', 'mrb_str_cat', 'mrb_str_cat_cstr', 'mrb_str_cat_str', 'mrb_str_append',
    'mrb_debug_get_position',
}


def die(msg):
    sys.stderr.write('native_binding_facts: %s\n' % msg)
    sys.exit(2)


def load_clang():
    extra = os.environ.get('LIBCLANG_PYTHONPATH')
    if extra:
        sys.path.insert(0, extra)
    try:
        from clang import cindex
    except ImportError:
        die("clang.cindex is not importable; enter `nix develop .#clang` or set LIBCLANG_PYTHONPATH")
    lib = os.environ.get('LIBCLANG_FILE')
    if lib:
        cindex.Config.set_library_file(lib)
    return cindex


def host_system_includes(cxx):
    env = dict(os.environ, LC_ALL='C', LANG='C')
    out = subprocess.run([cxx, '-E', '-x', 'c++', '-', '-v'], input='', capture_output=True, text=True, env=env).stderr
    dirs, on = [], False
    for line in out.splitlines():
        if line.startswith('#include <...> search starts here'):
            on = True
        elif line.startswith('End of search list'):
            break
        elif on:
            path = line.strip()
            # clang brings its own builtin headers; gcc's intrinsics do not parse
            if path and not re.search(r'/lib/gcc/[^/]+/[^/]+/include(-fixed)?$', path):
                dirs.append(path)
    return dirs


def derived_flags(root, third, build_dir, config):
    flags = ['-std=gnu++17', '-fno-rtti', '-fsyntax-only', '-Wno-everything']
    flags += CONFIG_DEFINES[config]
    for d in host_system_includes(os.environ.get('CXX', 'c++')):
        flags += ['-isystem', d]
    incs = [
        os.path.join(third, 'mruby/include'),
        os.path.join(build_dir, 'include'),
        os.path.join(third, 'uni-algo/include'),
        os.path.join(third, 'lvgl'),
        os.path.join(root, 'include'),
        os.path.join(third, 'stb'),
        os.path.join(build_dir, 'mrbgems/mruby-rgss'),
        os.path.join(root, 'mruby-rgss/src'),
    ]
    if config == 'psp':
        incs.insert(3, os.path.join(root, 'app/psp'))
    if config == 'wio':
        incs.insert(3, os.path.join(root, 'app/wio'))
    if config == 'maix':
        incs.insert(3, os.path.join(root, 'app/maix'))
    for inc in incs:
        flags.append('-I' + inc)
    return flags


def read_compile_commands(path, source):
    with open(path) as f:
        for entry in json.load(f):
            if os.path.abspath(os.path.join(entry.get('directory', '.'), entry['file'])) == os.path.abspath(source):
                args = entry.get('arguments') or entry['command'].split()
                return [a for a in args[1:] if a != source and a != '-c' and a != '-o' and not a.endswith('.o')]
    return None


class Extractor:
    def __init__(self, cindex, root, flags, third):
        self.third = third
        self.ci = cindex
        self.K = cindex.CursorKind
        self.root = os.path.realpath(root)
        self.flags = flags
        self.defs = {}  # usr -> facts for the definitions clang can see

    # -- helpers -------------------------------------------------------------

    def rel(self, path):
        real = os.path.realpath(path)
        return os.path.relpath(real, self.root) if real.startswith(self.root + os.sep) else real

    def ext(self, cur):
        e = cur.extent
        return [e.start.offset, e.end.offset]

    def strip(self, cur):
        K = self.K
        while cur.kind in (K.UNEXPOSED_EXPR, K.PAREN_EXPR):
            kids = list(cur.get_children())
            if len(kids) != 1:
                break
            cur = kids[0]
        return cur

    def body_of(self, cur):
        for kid in cur.get_children():
            if kid.kind == self.K.COMPOUND_STMT:
                return kid
        return None

    def in_repo(self, cur):
        # Vendored code other than mruby's own inline API cannot reach the
        # mruby frame except through an mrb_state it is handed, which the
        # callers' mrb_state-taking calls already account for.
        loc = cur.location
        if not loc.file or loc.is_in_system_header:
            return False
        path = os.path.realpath(str(loc.file))
        third = os.path.realpath(self.third)
        if path.startswith(third + os.sep):
            return path.startswith(os.path.join(third, 'mruby', 'include') + os.sep)
        return True

    def function_key(self, cur):
        usr = cur.get_usr()
        return usr or ('%s:%d:%d' % (cur.location.file, cur.location.line, cur.location.column))

    # -- per-function body scan ---------------------------------------------

    def scan_body(self, body):
        """Local facts of one function body: the reasons it reads the frame by
        itself and the functions it calls."""
        K = self.K
        reasons, callees, external = [], [], []
        gets = []
        flags = set()

        def visit(cur, top):
            k = cur.kind
            if k == K.GOTO_STMT or k == K.INDIRECT_GOTO_STMT or k == K.LABEL_STMT:
                flags.add('goto')
            elif k == K.MEMBER_REF_EXPR:
                ref = cur.referenced
                if ref is not None:
                    parent = ref.semantic_parent.spelling if ref.semantic_parent else ''
                    if (parent in ('mrb_context', 'mrb_callinfo', 'REnv') or
                            (parent == 'mrb_state' and ref.spelling in ('c', 'root_c', 'ci'))):
                        reasons.append('frame_field:%s.%s' % (parent, ref.spelling))
            elif k == K.CALL_EXPR:
                self.call(cur, reasons, callees, external, gets)
            for kid in cur.get_children():
                visit(kid, False)

        visit(body, True)
        self.last_flags = flags
        return reasons, callees, external, gets

    def call(self, cur, reasons, callees, external, gets):
        ref = cur.referenced
        name = cur.spelling
        if ref is None:
            reasons.append('indirect_call:%s@%s:%d' % (name or 'unresolved', os.path.basename(str(cur.location.file)), cur.location.line))
            return
        name = ref.spelling
        if name in FRAME_READERS:
            reasons.append('frame_api:%s' % name)
            if name == 'mrb_get_args':
                gets.append(cur)
            return
        d = ref.get_definition()
        if d is not None and self.in_repo(d):
            callees.append(self.register_def(d))
            return
        if d is not None:
            return  # system header definition (STL, libc): cannot see the frame
        takes_state = any('mrb_state' in a.type.spelling for a in ref.get_arguments())
        if takes_state:
            if name not in MRB_API_ALLOW:
                reasons.append('unknown_mrb_api:%s' % name)
            external.append(name)

    def register_def(self, d):
        key = self.function_key(d)
        if key not in self.defs:
            self.defs[key] = None  # break cycles
            body = self.body_of(d)
            if body is None:
                self.defs[key] = {'name': d.spelling, 'reasons': [], 'callees': [], 'external': [], 'in_repo': True}
            else:
                reasons, callees, external, _gets = self.scan_body(body)
                self.defs[key] = {'name': d.spelling, 'reasons': sorted(set(reasons)),
                                  'callees': sorted(set(callees)), 'external': sorted(set(external)),
                                  'line': d.location.line, 'file': self.rel(str(d.location.file))}
        return key

    def closure_external(self, external, callees):
        out = set(external)
        seen, stack = set(), list(callees)
        while stack:
            key = stack.pop()
            if key in seen:
                continue
            seen.add(key)
            info = self.defs.get(key)
            if info:
                out.update(info['external'])
                stack.extend(info['callees'])
        return sorted(out)

    def closure(self, reasons, callees):
        """Reasons of a body including everything it can reach."""
        out = list(reasons)
        seen, stack = set(), list(callees)
        while stack:
            key = stack.pop()
            if key in seen:
                continue
            seen.add(key)
            info = self.defs.get(key)
            if not info:
                continue
            for r in info['reasons']:
                out.append('%s (via %s)' % (r, info['name']))
            stack.extend(info['callees'])
        return sorted(set(out))

    # -- registrations -------------------------------------------------------

    def find_lambda(self, cur):
        K = self.K
        if cur.kind == K.LAMBDA_EXPR:
            return cur
        for kid in cur.get_children():
            found = self.find_lambda(kid)
            if found is not None:
                return found
        return None

    def target_facts(self, arg):
        K = self.K
        stripped = self.strip(arg)
        lam = self.find_lambda(stripped)
        if lam is not None:
            return self.callable_facts('lambda', lam, lam)
        if stripped.kind == K.DECL_REF_EXPR:
            ref = stripped.referenced
            if ref is not None and ref.kind == K.FUNCTION_DECL:
                d = ref.get_definition()
                if d is None:
                    return {'kind': 'external', 'name': ref.spelling}
                return self.callable_facts('function', d, d)
            if ref is not None and ref.kind == K.FUNCTION_TEMPLATE:
                return {'kind': 'template', 'name': ref.spelling}
            return {'kind': 'other', 'name': stripped.spelling}
        # template-id such as data_init_copy<Rect> is an UNEXPOSED_EXPR/DECL_REF_EXPR too
        return {'kind': 'other', 'name': stripped.spelling or stripped.kind.name}

    def callable_facts(self, kind, d, node):
        K = self.K
        if kind == 'lambda':
            params = [[kid.type.spelling, kid.spelling] for kid in node.get_children() if kid.kind == K.PARM_DECL]
            body = self.body_of(node)
            # a lambda registered as an mrb_func_t converts to that pointer type
            facts = {'kind': 'lambda', 'name': None, 'params': params, 'lambda_extent': self.ext(node),
                     'ret': 'mrb_value', 'template': False, 'decl_file': self.rel(str(node.location.file)),
                     'decl_line': node.location.line}
        else:
            params = [[a.type.spelling, a.spelling] for a in d.get_arguments()]
            body = self.body_of(d)
            facts = {'kind': 'function', 'name': d.spelling, 'params': params, 'ret': d.result_type.spelling,
                     'decl_file': self.rel(str(d.location.file)), 'decl_line': d.location.line,
                     'extent': self.ext(d), 'storage': str(d.storage_class).split('.')[-1],
                     'usr': d.get_usr(), 'template': d.specialized_template is not None, 'parent': d.semantic_parent.spelling if d.semantic_parent else '',
                     'parent_kind': d.semantic_parent.kind.name if d.semantic_parent else ''}
        if body is None:
            facts['body'] = None
            return facts
        facts['body_extent'] = self.ext(body)
        reasons, callees, external, gets = self.scan_body(body)
        facts['goto'] = 'goto' in self.last_flags
        facts['reasons'] = self.closure(reasons, callees)
        facts['external'] = self.closure_external(external, callees)
        facts['gets'] = [self.get_args_facts(g, body) for g in gets]
        facts['stmts'] = [self.stmt_facts(s) for s in body.get_children()]
        facts['ret_call'] = self.ret_call(body)
        facts['refs'] = self.refs_digest(body, facts['gets'])
        return facts

    def refs_digest(self, body, gets):
        """Digest of what the statements after the mrb_get_args call (all of
        them when there is none) refer to, in order.  A split moves those
        statements into another function; the digest proves each name still
        resolves to the same declaration there."""
        K = self.K
        kids = list(body.get_children())
        if len(gets) == 1:
            start = gets[0]['extent'][0]
            kids = [k for k in kids if k.extent.start.offset > start]
        refs = []
        local_parents = (K.FUNCTION_DECL, K.CXX_METHOD, K.CONSTRUCTOR, K.DESTRUCTOR, K.LAMBDA_EXPR)

        def visit(cur):
            k = cur.kind
            if k in (K.DECL_REF_EXPR, K.MEMBER_REF_EXPR, K.TYPE_REF, K.TEMPLATE_REF, K.NAMESPACE_REF, K.CALL_EXPR):
                ref = cur.referenced
                if ref is None:
                    refs.append('%s:?%s' % (k.name, cur.spelling))
                else:
                    parent = ref.semantic_parent
                    if parent is not None and parent.kind in local_parents:
                        # an argument is a local variable before the split, a parameter after
                        kind = 'VAR' if ref.kind in (K.VAR_DECL, K.PARM_DECL) else ref.kind.name
                        refs.append('local:%s:%s' % (kind, ref.spelling))
                    else:
                        usr = ref.get_usr() or ref.spelling
                        if '@Sa@' in usr:  # a lambda's own operator(): named after the function around it
                            usr = 'lambda:' + usr.split('@Sa@', 1)[1]
                        refs.append('%s:%s' % (k.name, usr))
            for kid in cur.get_children():
                visit(kid)

        for kid in kids:
            visit(kid)
        return hashlib.sha1('\n'.join(refs).encode()).hexdigest()

    def ret_call(self, body):
        """The call a body ends with (`return f(a, b);`), as spelled: the
        callee, its namespace and the plain identifiers passed."""
        K = self.K
        kids = list(body.get_children())
        if not kids or kids[-1].kind != K.RETURN_STMT:
            return None
        inner = list(kids[-1].get_children())
        if len(inner) != 1:
            return None
        call = self.strip(inner[0])
        if call.kind != K.CALL_EXPR or call.referenced is None:
            return None
        ref = call.referenced
        args = [self.identifier(a) for a in call.get_arguments()]
        parent = ref.semantic_parent
        return {'callee': ref.spelling, 'usr': ref.get_usr(), 'ns': parent.spelling if parent is not None else '',
                'args': args}

    def identifier(self, cur):
        """The variable an argument expression names, looking through the
        implicit copies and conversions clang wraps around it."""
        K = self.K
        while True:
            if cur.kind == K.DECL_REF_EXPR:
                return cur.spelling
            kids = list(cur.get_children())
            if len(kids) != 1 or cur.kind not in (K.UNEXPOSED_EXPR, K.PAREN_EXPR, K.CALL_EXPR):
                return None
            cur = kids[0]

    def stmt_facts(self, s):
        K = self.K
        f = {'kind': s.kind.name, 'extent': self.ext(s)}
        if s.kind == K.DECL_STMT:
            vars_ = []
            for v in s.get_children():
                if v.kind == K.VAR_DECL:
                    kids = [c for c in v.get_children() if c.kind not in (K.TYPE_REF, K.NAMESPACE_REF, K.TEMPLATE_REF)]
                    vars_.append({'name': v.spelling, 'type': v.type.spelling, 'has_init': bool(kids),
                                  'extent': self.ext(v), 'storage': str(v.storage_class).split('.')[-1]})
                else:
                    vars_.append({'name': v.spelling, 'type': v.kind.name, 'has_init': True, 'extent': self.ext(v),
                                  'storage': 'None'})
            f['vars'] = vars_
        return f

    def get_args_facts(self, call, body):
        K = self.K
        args = list(call.get_arguments())
        info = {'extent': self.ext(call), 'nargs': len(args), 'top_level': False, 'format': None, 'targets': []}
        if len(args) >= 2:
            fmt = self.strip(args[1])
            if fmt.kind == K.STRING_LITERAL:
                info['format'] = fmt.spelling.strip('"')
        for a in args[2:]:
            a = self.strip(a)
            if a.kind == K.UNARY_OPERATOR:
                inner = self.strip(next(iter(a.get_children()), a))
                if inner.kind == K.DECL_REF_EXPR and inner.referenced is not None and inner.referenced.kind == K.VAR_DECL:
                    info['targets'].append({'var': inner.spelling, 'type': inner.referenced.type.spelling,
                                            'line': inner.referenced.location.line})
                    continue
            info['targets'].append(None)
        for s in body.get_children():
            if self.strip(s) is call or s == call:
                info['top_level'] = True
            elif s.kind == K.CALL_EXPR and s.extent.start.offset == call.extent.start.offset:
                info['top_level'] = True
        return info

    # -- driver --------------------------------------------------------------

    def registrations(self, tu, source):
        K = self.K
        out = []
        source = os.path.realpath(source)

        def visit(cur, fn):
            for kid in cur.get_children():
                loc = kid.location
                if loc.file is None:
                    continue
                if kid.kind == K.CALL_EXPR and kid.spelling in REGISTRATION_APIS and os.path.realpath(str(loc.file)) == source:
                    args = list(kid.get_arguments())
                    if len(args) == 5:
                        reg = self.registration(kid, args)
                        reg['enclosing'] = {'name': fn.spelling, 'extent': self.ext(fn)} if fn is not None else None
                        out.append(reg)
                if os.path.realpath(str(loc.file)) == source or kid.kind == K.NAMESPACE:
                    inner = kid if kid.kind == K.FUNCTION_DECL and kid.is_definition() else fn
                    visit(kid, inner)

        visit(tu.cursor, None)
        return out

    def named_functions(self, tu, source):
        """Every function the file itself defines, by name: the `*_native_body`
        functions a split leaves behind and the binding functions they serve."""
        K = self.K
        source = os.path.realpath(source)
        out = {}

        def visit(cur):
            for kid in cur.get_children():
                if kid.location.file is None or os.path.realpath(str(kid.location.file)) != source:
                    continue
                if kid.kind == K.NAMESPACE:
                    visit(kid)
                elif kid.kind == K.FUNCTION_DECL and kid.is_definition():
                    body = self.body_of(kid)
                    reasons, callees, _external, gets = self.scan_body(body)
                    out.setdefault(kid.spelling, []).append({
                        'line': kid.location.line, 'extent': self.ext(kid), 'body_extent': self.ext(body),
                        'usr': kid.get_usr(), 'params': [[a.type.spelling, a.spelling] for a in kid.get_arguments()],
                        'ret': kid.result_type.spelling, 'reasons': self.closure(reasons, callees),
                        'goto': 'goto' in self.last_flags, 'storage': str(kid.storage_class).split('.')[-1],
                        'refs': self.refs_digest(body, [])})

        visit(tu.cursor)
        return out

    def exports(self, tu, source):
        """Functions the file defines in namespace rgss (the `_direct` entry
        points), with the call each one delegates to."""
        K = self.K
        source = os.path.realpath(source)
        out = []
        for top in tu.cursor.get_children():
            if top.kind != K.NAMESPACE or top.spelling != 'rgss' or top.location.file is None:
                continue
            for fn in top.get_children():
                if fn.kind != K.FUNCTION_DECL or not fn.is_definition() or fn.location.file is None:
                    continue
                if os.path.realpath(str(fn.location.file)) != source:
                    continue
                body = self.body_of(fn)
                reasons, callees, _external, _gets = self.scan_body(body)
                out.append({'name': fn.spelling, 'line': fn.location.line, 'extent': self.ext(fn),
                            'body_extent': self.ext(body), 'params': [[a.type.spelling, a.spelling] for a in fn.get_arguments()],
                            'ret_call': self.ret_call(body), 'reasons': self.closure(reasons, callees),
                            'stmts': len(list(body.get_children()))})
        return out

    def registration(self, call, args):
        K = self.K
        name_arg = self.strip(args[2])
        name = name_arg.spelling.strip('"') if name_arg.kind == K.STRING_LITERAL else None
        cls = self.strip(args[1])
        reg = {
            'api': call.spelling, 'kind': REGISTRATION_APIS[call.spelling],
            'line': call.location.line, 'extent': self.ext(call), 'name': name,
            'class_expr': cls.spelling if cls.kind == K.DECL_REF_EXPR else None,
            'arg_extents': [self.ext(a) for a in args],
            'target': self.target_facts(args[3]),
        }
        return reg


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    ap.add_argument('--config', default='host', choices=sorted(CONFIG_DEFINES))
    ap.add_argument('--third-party', default=os.environ.get('RGSS_THIRD_PARTY'))
    ap.add_argument('--build-dir', default=os.environ.get('RGSS_MRUBY_BUILD_DIR'),
                    help='mruby build directory holding include/mruby/presym and mrbgems/mruby-rgss/shinonome.hxx')
    ap.add_argument('--compile-commands', default=None)
    ap.add_argument('--emit-compile-commands', default=None)
    ap.add_argument('--out', default='-')
    ap.add_argument('sources', nargs='*')
    opts = ap.parse_args()

    root = os.path.realpath(opts.root)
    third = opts.third_party or os.path.join(root, '3rd')
    build_dir = opts.build_dir or os.path.join(root, 'build/mruby/host')
    sources = opts.sources or sorted(glob.glob(os.path.join(root, 'mruby-rgss/src/*.cxx')))
    sources = [os.path.realpath(s) for s in sources]

    if opts.emit_compile_commands:
        entries = []
        for cfg in sorted(CONFIG_DEFINES):
            for src in sources:
                entries.append({'directory': root, 'file': src, 'arguments': ['c++'] + derived_flags(root, third, build_dir, cfg) + [src]})
        with open(opts.emit_compile_commands, 'w') as f:
            json.dump(entries, f, indent=1)
        return

    ci = load_clang()
    result = {'config': opts.config, 'files': {}}
    for src in sources:
        flags = None
        if opts.compile_commands:
            flags = read_compile_commands(opts.compile_commands, src)
        if flags is None:
            flags = derived_flags(root, third, build_dir, opts.config)
        ex = Extractor(ci, root, flags, third)
        index = ci.Index.create()
        tu = index.parse(src, args=flags)
        errors = [d for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
        rel = ex.rel(src)
        regs = ex.registrations(tu, src)
        result['files'][rel] = {'errors': [str(d) for d in errors[:5]], 'registrations': regs,
                                'exports': ex.exports(tu, src),
                                'functions': ex.named_functions(tu, src)}
    text = json.dumps(result, indent=1, sort_keys=True)
    if opts.out == '-':
        sys.stdout.write(text + '\n')
    else:
        with open(opts.out, 'w') as f:
            f.write(text + '\n')


if __name__ == '__main__':
    main()
