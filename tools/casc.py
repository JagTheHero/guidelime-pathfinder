"""Minimal ctypes wrapper around CascLib for reading the WoW: Forever (wowf) local storage."""
import ctypes
import os

LIB = os.path.join(os.path.dirname(__file__), "..", "build", "casclib", "libcasc.so")
WOW_DIR = os.path.expanduser("~/Games/umu/battlenet/drive_c/Program Files (x86)/World of Warcraft")

CASC_OPEN_BY_NAME = 0
CASC_OPEN_BY_FILEID = 3
CASC_OVERCOME_ENCRYPTED = 0x20
CASC_LOCALE_ALL = 0xFFFFFFFF


class _Args(ctypes.Structure):
    _fields_ = [
        ("Size", ctypes.c_size_t),
        ("szLocalPath", ctypes.c_char_p),
        ("szCodeName", ctypes.c_char_p),
        ("szRegion", ctypes.c_char_p),
        ("PfnProgressCallback", ctypes.c_void_p),
        ("PtrProgressParam", ctypes.c_void_p),
        ("PfnProductCallback", ctypes.c_void_p),
        ("PtrProductParam", ctypes.c_void_p),
        ("dwLocaleMask", ctypes.c_uint32),
        ("dwFlags", ctypes.c_uint32),
        ("szBuildKey", ctypes.c_char_p),
        ("szCdnHostUrl", ctypes.c_char_p),
    ]


class Casc:
    def __init__(self, product="wowf", path=WOW_DIR):
        self.lib = ctypes.CDLL(os.path.abspath(LIB))
        L = self.lib
        L.CascOpenStorageEx.argtypes = [ctypes.c_char_p, ctypes.POINTER(_Args), ctypes.c_bool, ctypes.POINTER(ctypes.c_void_p)]
        L.CascOpenStorageEx.restype = ctypes.c_bool
        L.CascOpenFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
        L.CascOpenFile.restype = ctypes.c_bool
        L.CascGetFileSize64.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)]
        L.CascGetFileSize64.restype = ctypes.c_bool
        L.CascReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
        L.CascReadFile.restype = ctypes.c_bool
        L.CascCloseFile.argtypes = [ctypes.c_void_p]
        L.GetCascError.restype = ctypes.c_uint32
        args = _Args()
        args.Size = ctypes.sizeof(_Args)
        args.szLocalPath = path.encode()
        args.szCodeName = product.encode()
        args.dwLocaleMask = CASC_LOCALE_ALL
        self.h = ctypes.c_void_p()
        if not L.CascOpenStorageEx(None, ctypes.byref(args), False, ctypes.byref(self.h)):
            raise OSError(f"CascOpenStorageEx failed: {L.GetCascError()}")

    def _read(self, name, flags):
        fh = ctypes.c_void_p()
        if not self.lib.CascOpenFile(self.h, name, 0, flags | CASC_OVERCOME_ENCRYPTED, ctypes.byref(fh)):
            return None
        try:
            size = ctypes.c_uint64()
            self.lib.CascGetFileSize64(fh, ctypes.byref(size))
            buf = ctypes.create_string_buffer(size.value)
            got = ctypes.c_uint32()
            if not self.lib.CascReadFile(fh, buf, size.value, ctypes.byref(got)):
                return None
            return buf.raw[: got.value]
        finally:
            self.lib.CascCloseFile(fh)

    def read_fdid(self, fdid):
        return self._read(ctypes.c_void_p(fdid), CASC_OPEN_BY_FILEID)

    def read_name(self, name):
        return self._read(name.encode(), CASC_OPEN_BY_NAME)
