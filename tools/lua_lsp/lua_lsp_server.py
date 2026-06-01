#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Lua LSP 服务器
监视 LuaScripts 目录，使用 EmmyLua Language Server 进行语法检测
"""

import os
import sys
import json
import time
import re
import copy
import itertools
import subprocess
import threading
import logging
import argparse
import atexit
import signal
import traceback
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import unquote, urlparse

# watchdog 是可选依赖，仅用于监视模式
try:
    from watchdog.observers import Observer
    from watchdog.events import FileSystemEventHandler
    WATCHDOG_AVAILABLE = True
except ImportError:
    WATCHDOG_AVAILABLE = False
    Observer = None
    class FileSystemEventHandler:
        pass

from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

import math

# ========== EmmyLuaLS 默认配置 ==========

EMMYLUA_OVERRIDE_CONFIG = {
    "runtime": {
        "version": "Lua5.4",
        "requireLikeFunction": ["tolua"],
        "special": {
            "tolua": "require",
        },
    },
    "workspace": {},
    "diagnostics": {
        "enable": True,
        "globals": ["tolua"],
        "severity": {
            # --- 跟默认一致，不 override ---
            # "undefined-global": "error",          # 默认 error
            # "unused": "hint",                     # 默认 hint
            # "unbalanced-assignments": "warning",  # 默认 warning
            # "cast-type-mismatch": "warning",      # 默认 warning

            # --- 提升到 error（默认 warning）---
            "undefined-field": "error",
            "missing-parameter": "error",
            "param-type-mismatch": "error",
            "assign-type-mismatch": "error",
            "return-type-mismatch": "error",
            "type-not-found": "error",
            "undefined-doc-param": "error",
            "circle-doc-class": "error",
            "inject-field": "error",
            "access-invisible": "error",
            "enum-value-mismatch": "error",
            "duplicate-index": "error",
            "require-module-not-visible": "error",
            "attribute-param-type-mismatch": "error",
            "generic-constraint-mismatch": "error",

            # --- 待提升 ---
            # "unresolved-require": "error", # 默认 warning
            # "redundant-parameter": "error", # 默认 warning
            # "read-only": "error",


            # --- 调整级别 ---
            "duplicate-set-field": "hint",   # 默认 warning → hint
            "redefined-local": "warning",    # 默认 hint → warning
            "call-non-callable": "warning",  # ScriptObject() 有 __call 但类型未声明，待强化声明后改 error
        },
    },
    "completion": {
        "autoRequire": False,
    },
    "hint": {
        "enable": True,
    },
}

# ========== 分页工具函数 ==========

def paginate_result(result: dict, page: int = 1, page_size: int = 20,
                    page_max_bytes: int = 16000) -> dict:
    """对 LSP 结果进行分页处理

    同时使用数量限制和字节限制，取页数更大的（更安全，每页内容更少）

    Args:
        result: LSP 返回结果 {"ok": True, "result": ...}
        page: 页码（从 1 开始）
        page_size: 每页数量上限（1-100，默认 20）
        page_max_bytes: 每页最大字节数（默认 16000，约 4000 tokens）

    Returns:
        添加分页元数据的结果
    """
    if not result.get('ok'):
        return result

    lsp_result = result.get('result')
    if lsp_result is None:
        return result

    # 处理不同的结果格式
    items = None
    items_key = None

    # completion 结果格式: {"items": [...], "isIncomplete": bool}
    if isinstance(lsp_result, dict) and 'items' in lsp_result:
        items = lsp_result['items']
        items_key = 'items'
    # 其他结果格式: 直接是数组
    elif isinstance(lsp_result, list):
        items = lsp_result
        items_key = None
    else:
        # 非数组结果（如 hover），不分页
        return result

    if not items:
        return result

    total = len(items)
    page_size = max(1, min(page_size, 100))

    # 计算两种分页方式的页数
    total_pages_by_count = math.ceil(total / page_size)
    total_pages_by_bytes = _calc_total_pages_by_bytes(items, page_max_bytes)

    # 取更大的页数（更安全，每页内容更少）
    if total_pages_by_bytes >= total_pages_by_count:
        use_bytes_limit = True
        total_pages = total_pages_by_bytes
    else:
        use_bytes_limit = False
        total_pages = total_pages_by_count

    page = max(1, min(page, max(1, total_pages)))

    if use_bytes_limit:
        paginated_items = _get_page_by_bytes(items, page, page_max_bytes)
    else:
        start_idx = (page - 1) * page_size
        end_idx = start_idx + page_size
        paginated_items = items[start_idx:end_idx]

    displayed = len(paginated_items)
    hidden = total - displayed

    pagination_info = {
        'total': total,
        'displayed': displayed,
        'hidden': hidden,
        'page': page,
        'total_pages': total_pages
    }

    # 只有需要分页时才添加 pagination
    if hidden > 0:
        if page < total_pages:
            pagination_info['hint'] = f'使用 --page {page + 1} 查看下一页（共 {total_pages} 页），或 --page-size 调整每页数量'
        else:
            pagination_info['hint'] = '这是最后一页，使用 --page 1 返回第一页，或 --page-size 调整每页数量'
    else:
        pagination_info = None

    # pagination 放最前面
    response = {'ok': True}
    if pagination_info:
        response['pagination'] = pagination_info

    if items_key:
        new_result = dict(lsp_result)
        new_result[items_key] = paginated_items
        response['result'] = new_result
    else:
        response['result'] = paginated_items

    return response


def _get_page_by_bytes(items: list, page: int, max_bytes: int) -> list:
    """按字节数分页，返回指定页的 items"""
    if not items:
        return []

    pages = []
    current_page_start = 0
    current_page_bytes = 0

    for i, item in enumerate(items):
        size = len(json.dumps(item, ensure_ascii=False).encode('utf-8'))
        if current_page_bytes + size > max_bytes and i > current_page_start:
            pages.append((current_page_start, i))
            current_page_start = i
            current_page_bytes = size
        else:
            current_page_bytes += size

    if current_page_start < len(items):
        pages.append((current_page_start, len(items)))

    page_idx = max(0, min(page - 1, len(pages) - 1))
    if pages:
        start_idx, end_idx = pages[page_idx]
        return items[start_idx:end_idx]
    return []


def _calc_total_pages_by_bytes(items: list, max_bytes: int) -> int:
    """计算按字节数分页的总页数"""
    if not items:
        return 1

    pages = 1
    current_page_bytes = 0

    for item in items:
        size = len(json.dumps(item, ensure_ascii=False).encode('utf-8'))
        if current_page_bytes + size > max_bytes and current_page_bytes > 0:
            pages += 1
            current_page_bytes = size
        else:
            current_page_bytes += size

    return pages


# LSP Notification 方法列表（不需要响应）
LSP_NOTIFICATION_METHODS = {
    'initialized',
    'exit',
    'textDocument/didOpen',
    'textDocument/didClose',
    'textDocument/didChange',
    'textDocument/didSave',
    'textDocument/willSave',
    'workspace/didChangeConfiguration',
    'workspace/didChangeWatchedFiles',
    'workspace/didChangeWorkspaceFolders',
    '$/cancelRequest',
    '$/setTrace',
}

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)

logger = logging.getLogger(__name__)


class Color:
    """终端颜色"""
    RED = '\033[91m'
    YELLOW = '\033[93m'
    GREEN = '\033[92m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    RESET = '\033[0m'
    BOLD = '\033[1m'


class DiagnosticFormatter:
    """诊断信息格式化器"""
    
    SEVERITY_NAMES = {
        1: "错误",
        2: "警告",
        3: "信息",
        4: "提示"
    }
    
    SEVERITY_COLORS = {
        1: Color.RED,
        2: Color.YELLOW,
        3: Color.BLUE,
        4: Color.CYAN
    }
    
    @staticmethod
    def format_diagnostic(file_path: str, diagnostic: dict, use_color: bool = True) -> str:
        """格式化单个诊断信息"""
        severity = diagnostic.get('severity', 1)
        message = diagnostic.get('message', '')
        range_info = diagnostic.get('range', {})
        start = range_info.get('start', {})
        line = start.get('line', 0) + 1  # LSP 行号从 0 开始
        character = start.get('character', 0) + 1
        
        severity_name = DiagnosticFormatter.SEVERITY_NAMES.get(severity, "未知")
        
        # 获取文件名（而不是完整路径）
        file_name = os.path.basename(file_path)
        
        if use_color:
            color = DiagnosticFormatter.SEVERITY_COLORS.get(severity, Color.WHITE)
            output = f"{Color.BOLD}{file_name}{Color.RESET}:{line}:{character}: "
            output += f"{color}{severity_name}{Color.RESET}: {message}"
        else:
            output = f"{file_name}:{line}:{character}: {severity_name}: {message}"
        
        return output
    
    @staticmethod
    def format_summary(diagnostics: Dict[str, List], use_color: bool = True) -> str:
        """格式化摘要信息"""
        total_files = len(diagnostics)
        error_count = 0
        warning_count = 0
        info_count = 0
        hint_count = 0
        
        for diags in diagnostics.values():
            for diag in diags:
                severity = diag.get('severity', 1)
                if severity == 1:
                    error_count += 1
                elif severity == 2:
                    warning_count += 1
                elif severity == 3:
                    info_count += 1
                elif severity == 4:
                    hint_count += 1
        
        if use_color:
            summary = f"\n{Color.BOLD}{'='*60}{Color.RESET}\n"
            summary += f"{Color.BOLD}诊断摘要{Color.RESET}\n"
            summary += f"{'='*60}\n"
            summary += f"检查文件数: {Color.CYAN}{total_files}{Color.RESET}\n"
            summary += f"{Color.RED}错误: {error_count}{Color.RESET} | "
            summary += f"{Color.YELLOW}警告: {warning_count}{Color.RESET} | "
            summary += f"{Color.BLUE}信息: {info_count}{Color.RESET} | "
            summary += f"{Color.CYAN}提示: {hint_count}{Color.RESET}\n"
            summary += f"{'='*60}\n"
        else:
            summary = f"\n{'='*60}\n"
            summary += f"诊断摘要\n"
            summary += f"{'='*60}\n"
            summary += f"检查文件数: {total_files}\n"
            summary += f"错误: {error_count} | 警告: {warning_count} | "
            summary += f"信息: {info_count} | 提示: {hint_count}\n"
            summary += f"{'='*60}\n"
        
        return summary


class LSPProtocol:
    """LSP 协议处理"""
    
    @staticmethod
    def encode_message(content: dict) -> bytes:
        """编码 LSP 消息"""
        body = json.dumps(content, ensure_ascii=False)
        content_bytes = body.encode('utf-8')
        header = f"Content-Length: {len(content_bytes)}\r\n\r\n"
        return header.encode('utf-8') + content_bytes
    
    @staticmethod
    def decode_message(data: bytes) -> Optional[dict]:
        """解码 LSP 消息"""
        try:
            # 查找头部结束位置
            header_end = data.find(b'\r\n\r\n')
            if header_end == -1:
                return None
            
            # 解析 Content-Length
            header = data[:header_end].decode('utf-8')
            content_length = None
            for line in header.split('\r\n'):
                if line.startswith('Content-Length:'):
                    content_length = int(line.split(':')[1].strip())
                    break
            
            if content_length is None:
                return None
            
            # 提取消息体
            body_start = header_end + 4
            body = data[body_start:body_start + content_length]
            
            if len(body) < content_length:
                return None
            
            return json.loads(body.decode('utf-8'))
        except Exception as e:
            logger.error(f"解码消息失败: {e}")
            return None


class LuaFileWatcher(FileSystemEventHandler):
    """Lua 文件监视器"""
    
    def __init__(self, server):
        self.server = server
        self.last_check = {}
        self.debounce_time = 1.0  # 防抖时间（秒）
        self.file_settle_time = 0.5  # 文件稳定等待时间（秒）
    
    def _wait_for_file_ready(self, file_path: str, max_retries: int = 3) -> bool:
        """等待文件写入完成并可读"""
        for i in range(max_retries):
            try:
                # 尝试以独占模式打开文件，检查是否被占用
                with open(file_path, 'r', encoding='utf-8') as f:
                    # 读取一个字节确认可读
                    f.read(1)
                return True
            except (PermissionError, IOError):
                if i < max_retries - 1:
                    time.sleep(self.file_settle_time)
                    continue
                return False
        return False
    
    def _cleanup_old_entries(self):
        """清理旧的防抖记录，保留最近 100 个"""
        if len(self.last_check) > 100:
            # 按时间排序，保留最新的 100 个
            sorted_items = sorted(self.last_check.items(), key=lambda x: x[1], reverse=True)
            self.last_check = dict(sorted_items[:100])

    def _matches_watch_pattern(self, path: str) -> bool:
        """检查文件是否匹配 emmylua_ls 注册的监视模式"""
        fname = os.path.basename(path)
        for pattern in self.server._watch_patterns:
            # "**/*.lua" → 匹配 .lua 后缀
            if pattern.startswith('**/*.') and fname.endswith(pattern[4:]):
                return True
            # "**/.luarc.json" → 匹配文件名
            if pattern.startswith('**/') and not pattern.startswith('**/*.') and fname == pattern[3:]:
                return True
        # registerCapability 还没收到时兜底匹配 .lua
        if not self.server._watch_patterns:
            return fname.endswith('.lua')
        return False

    def _notify_watched_file(self, file_path: str, change_type: int):
        """通过 didChangeWatchedFiles 通知 emmylua_ls"""
        uri = Path(file_path).resolve().as_uri()
        self.server._send_message({
            "jsonrpc": "2.0",
            "method": "workspace/didChangeWatchedFiles",
            "params": {
                "changes": [{"uri": uri, "type": change_type}]
            }
        })

    def on_modified(self, event):
        if event.is_directory or not self._matches_watch_pattern(event.src_path):
            return

        current_time = time.time()
        if event.src_path in self.last_check:
            if current_time - self.last_check[event.src_path] < self.debounce_time:
                return
        self.last_check[event.src_path] = current_time
        self._cleanup_old_entries()
        logger.info(f"检测到文件变化: {event.src_path}")

        if self._wait_for_file_ready(event.src_path):
            if event.src_path.endswith('.lua'):
                self.server.check_file(event.src_path)
            self._notify_watched_file(event.src_path, 2)  # Changed
        else:
            logger.warning(f"文件可能正在被占用，跳过检查: {event.src_path}")

    def on_created(self, event):
        if event.is_directory or not self._matches_watch_pattern(event.src_path):
            return

        logger.info(f"检测到新文件: {event.src_path}")
        time.sleep(self.file_settle_time)

        if self._wait_for_file_ready(event.src_path):
            if event.src_path.endswith('.lua'):
                self.server.check_file(event.src_path)
            self._notify_watched_file(event.src_path, 1)  # Created
            self._cleanup_old_entries()
        else:
            logger.warning(f"文件可能正在被复制，跳过检查: {event.src_path}")

    def on_deleted(self, event):
        if event.is_directory or not self._matches_watch_pattern(event.src_path):
            return

        logger.info(f"检测到文件删除: {event.src_path}")
        if event.src_path.endswith('.lua'):
            self.server.close_file(event.src_path)
        self._notify_watched_file(event.src_path, 3)  # Deleted


class LuaLSPServer:
    """Lua LSP 服务器"""
    
    def __init__(self, lua_scripts_dir: str, output_file: str = "lua_diagnostics.log",
                 errors_only_file: str = "lua_errors.log", mode: str = "watch",
                 config_path: str = None, lsp_path: str = None):
        self.lua_scripts_dir = Path(lua_scripts_dir).resolve()
        self.config_path = Path(config_path).resolve() if config_path else None
        self.output_file = output_file
        self.errors_only_file = errors_only_file
        self.mode = mode  # 运行模式: "watch" 或 "check"
        self._lsp_path = lsp_path
        self.diagnostics: Dict[str, List] = {}
        self.lsp_process: Optional[subprocess.Popen] = None
        self._id_counter = itertools.count(1)
        self.running = False
        self.lock = threading.Lock()
        self.opened_files: Dict[str, int] = {}
        self.use_color = sys.stdout.isatty()
        # emmylua_ls 通过 client/registerCapability 注册的文件监视模式
        self._watch_patterns: List[str] = []
        self._restart_count = 0
        self._write_lock = threading.Lock()

        # HTTP RPC 代理相关
        self._pending_requests: Dict[int, dict] = {}
        self._pending_lock = threading.Lock()
        self.http_port = 0

        # 从 .luarc.json / .emmyrc.json 读取 .emmylua 路径
        self.emmylua_dir = self._find_emmylua_dir()

        # 查找可执行文件
        self.lsp_executable = self._find_executable('emmylua_ls')
        self.check_executable = self._find_executable('emmylua_check')

        if self.mode == 'check' and not self.check_executable:
            logger.error("未找到 emmylua_check，请确保已安装")
            sys.exit(1)
        if self.mode == 'watch' and not self.lsp_executable:
            logger.error("未找到 emmylua_ls，请确保已安装")
            sys.exit(1)

        exe = self.check_executable if self.mode == 'check' else self.lsp_executable
        logger.info(f"使用 LSP: {exe}")
        logger.info(f"监视目录: {self.lua_scripts_dir}")
        logger.info(f"EmmyLua 类型: {self.emmylua_dir}")
    
    def _find_emmylua_dir(self) -> Path:
        """从配置文件读取 .emmylua 路径"""
        # 如果指定了配置文件路径，优先使用
        if self.config_path and self.config_path.exists():
            luarc_path = self.config_path
            logger.info(f"使用指定的配置文件: {luarc_path}")
        else:
            luarc_path = self.lua_scripts_dir / ".luarc.json"
            if not luarc_path.exists():
                luarc_path = self.lua_scripts_dir / ".emmyrc.json"

        if luarc_path.exists():
            try:
                # 使用 utf-8-sig 自动处理 BOM
                with open(luarc_path, 'r', encoding='utf-8-sig') as f:
                    luarc = json.load(f)
                
                # 优先读取顶层自定义字段 emmyluaDir
                emmylua_dir = luarc.get('emmyluaDir')
                if emmylua_dir:
                    if not os.path.isabs(emmylua_dir):
                        # 相对路径从配置文件所在目录计算
                        config_dir = luarc_path.parent
                        return (config_dir / emmylua_dir).resolve()
                    else:
                        return Path(emmylua_dir).resolve()
                
                # 兜底：从 workspace.library 中查找
                library = luarc.get('workspace', {}).get('library', [])
                for lib_path in library:
                    if not os.path.isabs(lib_path):
                        # 相对路径从配置文件所在目录计算
                        config_dir = luarc_path.parent
                        abs_path = (config_dir / lib_path).resolve()
                    else:
                        abs_path = Path(lib_path).resolve()
                    
                    if abs_path.name == '.emmylua' or '.emmylua' in str(abs_path):
                        return abs_path
                
                logger.warning(f".luarc.json 中未找到 emmyluaDir 或 .emmylua 配置")
            except Exception as e:
                logger.error(f"读取 .luarc.json 失败: {e}")
        else:
            logger.warning(f".luarc.json 不存在: {luarc_path}")

        # fallback：向上查找 .emmylua 目录
        for candidate in [self.lua_scripts_dir / '.emmylua',
                          self.lua_scripts_dir.parent / '.emmylua',
                          self.lua_scripts_dir.parent.parent / '.emmylua']:
            if candidate.exists():
                return candidate.resolve()
        return self.lua_scripts_dir / ".emmylua"
    
    def _load_override_config(self) -> dict:
        """加载 override 配置：优先读脚本同目录的 .emmyrc.override.json，否则用内联"""
        override_file = Path(__file__).resolve().parent / '.emmyrc.override.json'
        if override_file.exists():
            try:
                with open(override_file, 'r', encoding='utf-8-sig') as f:
                    config = json.load(f)
                logger.info(f"使用外部 override 配置: {override_file}")
                return config
            except Exception as e:
                logger.warning(f"读取 override 配置失败，回退到内联: {e}")
        return copy.deepcopy(EMMYLUA_OVERRIDE_CONFIG)

    def _normalize_project_severity(self, override: dict):
        """读项目 .luarc.json/.emmyrc.json 的 severity，转小写合入 override"""
        for name in ['.luarc.json', '.emmyrc.json']:
            config_file = self.lua_scripts_dir / name
            if config_file.exists():
                try:
                    with open(config_file, 'r', encoding='utf-8-sig') as f:
                        project = json.load(f)
                    severity = project.get('diagnostics', {}).get('severity', {})
                    if severity:
                        override_sev = override.setdefault('diagnostics', {}).setdefault('severity', {})
                        for code, level in severity.items():
                            if code not in override_sev and isinstance(level, str):
                                override_sev[code] = level.lower()
                except Exception:
                    pass
                break

    def _resolve_workspace_paths(self) -> dict:
        """基于 lua_scripts_dir 解析 library/packages 路径（相对路径）"""
        ws = self.lua_scripts_dir
        result = {}

        # library: .emmylua 声明目录（绝对路径，../相对路径在emmylua_check中不可靠）
        library = []
        for candidate in [ws / '.emmylua', ws.parent / '.emmylua', ws.parent.parent / '.emmylua']:
            if candidate.exists():
                library.append(str(candidate.resolve()))
                break
        if library:
            result['library'] = library

        # packages: urhox-libs 库目录（绝对路径，../相对路径在emmylua_check中有bug）
        packages = []
        for candidate in [ws / 'urhox-libs', ws.parent / 'urhox-libs', ws.parent.parent / 'urhox-libs']:
            if candidate.exists():
                packages.append(str(candidate.resolve()))
                break
        if packages:
            result['packages'] = packages

        return result

    def _find_executable(self, name: str) -> Optional[str]:
        """查找可执行文件 (emmylua_ls / emmylua_check)"""
        exe_name = f'{name}.exe' if os.name == 'nt' else name

        # 1. 用户指定路径（仅当文件名匹配时使用）
        if self._lsp_path:
            lsp_path = Path(self._lsp_path)
            if lsp_path.exists() and lsp_path.stem == name:
                return str(lsp_path.resolve())

        # 2. 本地安装目录
        script_dir = Path(__file__).resolve().parent
        local_bin = script_dir / 'bin' / exe_name
        if local_bin.exists():
            return str(local_bin)

        # 3. 从 PATH 中查找
        try:
            cmd = 'which' if os.name != 'nt' else 'where'
            result = subprocess.run([cmd, exe_name],
                                  capture_output=True, text=True, shell=False)
            if result.returncode == 0:
                return result.stdout.strip().split('\n')[0].strip()
        except Exception:
            pass

        return None
    
    def start(self):
        """启动 LSP 服务器（根据模式选择）"""
        if self.mode == "check":
            self.start_check_mode()
        else:
            self.start_watch_mode()
    
    def start_check_mode(self):
        """单次检查模式（使用 emmylua_check）"""
        if self.use_color:
            logger.info(f"\n{Color.CYAN}{'='*60}{Color.RESET}")
            logger.info(f"{Color.BOLD}🔍 执行单次检查...{Color.RESET}")
            logger.info(f"{Color.CYAN}{'='*60}{Color.RESET}")
        else:
            logger.info(f"\n{'='*60}")
            logger.info(f"🔍 执行单次检查...")
            logger.info(f"{'='*60}")

        try:
            if os.name == 'nt':
                config_cache_dir = os.path.join(os.environ.get('TEMP', 'C:/Temp'), 'emmylua-check-cache')
            else:
                config_cache_dir = '/tmp/emmylua-check-cache'
            os.makedirs(config_cache_dir, exist_ok=True)

            ts = int(time.time() * 1000)
            check_json_path = Path(config_cache_dir) / f'check-{ts}.json'

            override = self._load_override_config()
            override['workspace'] = self._resolve_workspace_paths()
            self._normalize_project_severity(override)
            override = {k: v for k, v in override.items() if not k.startswith('$')}

            override_config_path = os.path.join(config_cache_dir, f'override-{ts}.json')
            with open(override_config_path, 'w', encoding='utf-8') as f:
                json.dump(override, f, indent=2)

            # 构建 --config 参数：项目配置在前（base），override 在后（覆盖）
            # emmylua_check 按顺序 deep merge 多个配置文件
            config_files = []
            if self.config_path and self.config_path.exists():
                config_files.append(str(self.config_path))
            else:
                for name in ['.emmyrc.json', '.luarc.json']:
                    candidate = self.lua_scripts_dir / name
                    if candidate.exists():
                        config_files.append(str(candidate))
                        break
            config_files.append(override_config_path)

            # 构建 emmylua_check 命令
            cmd = [
                self.check_executable,
                str(self.lua_scripts_dir),
                '--output-format', 'json',
                '--output', str(check_json_path),
                '--config', ','.join(config_files),
            ]

            if logger.isEnabledFor(logging.DEBUG):
                cmd.append('--verbose')

            logger.info(f"执行命令: {' '.join(cmd)}")

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding='utf-8',
                timeout=300
            )

            logger.debug(f"命令退出码: {result.returncode}")

            # 清理临时 override 配置
            Path(override_config_path).unlink(missing_ok=True)

            if check_json_path.exists():
                with open(check_json_path, 'r', encoding='utf-8') as f:
                    json_content = f.read()
                check_json_path.unlink(missing_ok=True)

                logger.debug(f"JSON 内容长度: {len(json_content)}")
                self._parse_json_output(json_content)
            elif result.stdout or result.stderr:
                logger.info("JSON 输出文件未生成，回退到文本格式解析")
                self._parse_check_output(result.stdout, result.stderr)

            # 保存诊断结果
            with self.lock:
                self._save_diagnostics()
                self._save_errors_only()

            # 输出摘要
            with self.lock:
                summary = DiagnosticFormatter.format_summary(self.diagnostics, use_color=self.use_color)
                logger.info(summary)

            if self.use_color:
                logger.info(f"{Color.GREEN}✓ 检查完成{Color.RESET}")
            else:
                logger.info("✓ 检查完成")

        except subprocess.TimeoutExpired:
            logger.error("检查超时（超过5分钟）")
            sys.exit(1)
        except Exception as e:
            logger.error(f"检查失败: {e}")

            logger.error(traceback.format_exc())
            sys.exit(1)
    
    def _parse_check_output(self, stdout: str, stderr: str):
        """解析 check 模式的输出并转换为 LSP 诊断格式"""
        output = stdout + stderr
        
        if self.use_color:
            logger.info(f"\n{Color.CYAN}{'─'*60}{Color.RESET}")
            logger.info(f"{Color.BOLD}正在解析诊断输出...{Color.RESET}")
            logger.info(f"{Color.CYAN}{'─'*60}{Color.RESET}\n")
        
        logger.debug(f"输出总长度: {len(output)} 字符")
        
        # 检查是否为空输出
        if not output.strip():
            logger.warning("emmylua_check 返回空输出")
            logger.info("提示：这可能意味着：")
            logger.info("  1. 没有找到任何 Lua 文件")
            logger.info("  2. 配置文件有误")
            logger.info("  3. emmylua_check 版本不兼容")
            return
        
        # 显示前几行原始输出用于调试（仅在 DEBUG 模式）
        lines = output.split('\n')
        logger.debug(f"输出行数: {len(lines)}")
        if logger.isEnabledFor(logging.DEBUG):
            logger.debug(f"前 30 行原始输出：")
            for i, line in enumerate(lines[:30]):
                logger.debug(f"  [{i:2d}] {repr(line)}")
        
        # 尝试 JSON 格式解析
        if output.strip().startswith('{') or output.strip().startswith('['):
            logger.info("检测到 JSON 格式输出，尝试解析...")
            try:
                json_data = json.loads(output)
                self._parse_json_output(output)
                return
            except json.JSONDecodeError as e:
                logger.warning(f"JSON 解析失败: {e}")
        
        # 文本格式解析
        parsed_count = 0
        failed_lines = []
        
        for i, line in enumerate(lines):
            line = line.strip()
            if not line:
                continue
            
            # 跳过进度/状态信息和空行
            line_lower = line.lower()
            if (not line or 
                line.startswith('>') or  # 进度条
                'initializing' in line_lower or
                'diagnosis complete' in line_lower or
                'found' in line_lower and 'problems' in line_lower or
                len(line) < 10 or  # 太短的行
                line.replace(' ', '').replace('^', '') == ''):  # 只包含空格和 ^ 的行
                logger.debug(f"跳过: {line[:80]}")
                continue
            
            # 解析诊断行（emmylua_check 文本输出格式）
            diagnostic = self._parse_check_line(line)
            if diagnostic:
                logger.debug(f"成功解析 [{i}]: {diagnostic}")
                file_path = diagnostic['file']
                
                # 转换为与 LSP publishDiagnostics 兼容的格式
                lsp_diagnostic = {
                    'severity': diagnostic['severity'],
                    'range': {
                        'start': {
                            'line': diagnostic['line'] - 1,  # 转为 0-based
                            'character': diagnostic['column'] - 1
                        }
                    },
                    'message': diagnostic['message'],
                    'code': diagnostic.get('code', '')
                }
                
                if file_path not in self.diagnostics:
                    self.diagnostics[file_path] = []
                self.diagnostics[file_path].append(lsp_diagnostic)
                
                # 实时输出（复用现有格式）
                formatted = DiagnosticFormatter.format_diagnostic(
                    file_path, lsp_diagnostic, use_color=self.use_color)
                logger.info(formatted)
                parsed_count += 1
            else:
                # 记录无法解析的行
                if len(line) > 10:  # 只记录有意义的行
                    failed_lines.append((i, line))
        
        if parsed_count > 0:
            logger.info(f"成功解析了 {parsed_count} 条诊断信息")
        else:
            logger.warning(f"未能解析任何诊断信息")
        
        if failed_lines and parsed_count == 0:
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug(f"有 {len(failed_lines)} 行无法解析，显示前 10 行：")
                for i, line in failed_lines[:10]:
                    logger.debug(f"  行 [{i}]: {line[:100]}")
    
    def _parse_json_output(self, json_content: str):
        """解析 JSON 格式的 check 输出

        emmylua_check 格式: [ {"file": "path", "diagnostics": [{LSP Diagnostic}]} ]
        """
        try:
            data = json.loads(json_content)

            # emmylua_check: 数组格式 [{file, diagnostics}]
            if isinstance(data, list):
                for entry in data:
                    file_path_raw = entry.get('file', '')
                    diagnostics = entry.get('diagnostics', [])
                    if not diagnostics:
                        continue
                    # 标准化路径
                    try:
                        file_path = str(Path(file_path_raw).resolve())
                    except Exception:
                        file_path = file_path_raw
                    logger.info(f"文件: {os.path.basename(file_path)}, 诊断数: {len(diagnostics)}")
                    for diag in diagnostics:
                        self._process_json_diagnostic(file_path, diag)

            else:
                logger.warning(f"意外的 JSON 格式: {type(data)}")
                return

            total_issues = sum(len(diags) for diags in self.diagnostics.values())
            logger.info(f"解析完成: {len(self.diagnostics)} 个文件, {total_issues} 个问题")

        except json.JSONDecodeError as e:
            logger.error(f"JSON 解析失败: {e}")
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug(f"JSON 内容:\n{json_content[:500]}")
        except Exception as e:
            logger.error(f"处理 JSON 时出错: {e}")
            if logger.isEnabledFor(logging.DEBUG):
    
                logger.debug(traceback.format_exc())
    
    def _uri_to_path(self, uri: str) -> str:
        """转换 URI 到本地文件路径（标准化格式）"""
        parsed = urlparse(uri)
        path = unquote(parsed.path)

        # Windows: /g:/path -> g:\path 或 /G:/path -> G:\path
        if os.name == 'nt':
            if path.startswith('/') and len(path) > 2 and path[2] == ':':
                path = path[1:]  # 去掉开头的 /
            path = path.replace('/', '\\')

        # 标准化路径（解决大小写不一致问题）
        # Windows 上 Path.resolve() 会统一驱动器字母大小写
        try:
            path = str(Path(path).resolve())
        except Exception:
            pass  # 保持原路径

        return path
    
    def _add_diagnostic_to_store(self, file_path: str, diagnostic: dict, show_output: bool = True):
        """统一的诊断添加方法（供 check 和 watch 模式复用）
        
        Args:
            file_path: 文件路径
            diagnostic: LSP 格式的诊断对象
            show_output: 是否显示实时输出
        """
        if file_path not in self.diagnostics:
            self.diagnostics[file_path] = []
        self.diagnostics[file_path].append(diagnostic)
        
        if show_output:
            formatted = DiagnosticFormatter.format_diagnostic(
                file_path, diagnostic, use_color=self.use_color)
            logger.info(formatted)
    
    def _process_json_diagnostic(self, file_path: str, diag: dict):
        """处理单个 JSON 诊断项（check 模式）"""
        try:
            # LSP 标准格式
            # 只需要确保字段完整性
            lsp_diagnostic = {
                'severity': diag.get('severity', 1),
                'range': diag.get('range', {'start': {'line': 0, 'character': 0}}),
                'message': diag.get('message', '').strip(),
                'code': diag.get('code', '')
            }
            
            logger.debug(f"添加诊断: {os.path.basename(file_path)} -> {lsp_diagnostic['message'][:50]}")
            
            # 使用统一的添加方法
            self._add_diagnostic_to_store(file_path, lsp_diagnostic, show_output=True)
            
        except Exception as e:
            logger.error(f"处理诊断项失败: {e}")
            logger.debug(f"诊断数据: {diag}")

            logger.debug(traceback.format_exc())
    
    def _parse_check_line(self, line: str) -> dict:
        """解析 check 输出的单行诊断
        
        支持的格式：
        1. 带 ANSI 颜色: \x1b[34mfile.lua:22:37\x1b[0m [\x1b[31mError\x1b[0m] message
        2. 无颜色: file.lua:22:37 [Error] message
        3. 传统格式: file.lua:22:37: error: message
        """
        try:
            # 步骤1: 去除 ANSI 颜色代码（如果有）
            # ANSI 格式: \x1b[数字;数字m 或 \x1b[数字m
            clean_line = re.sub(r'\x1b\[[0-9;]*m', '', line)
            logger.debug(f"原始: {line[:100]}")
            logger.debug(f"清理后: {clean_line[:150]}")
            
            # 步骤2: 查找 .lua: 模式
            lua_pos = clean_line.find('.lua:')
            if lua_pos == -1:
                logger.debug(f"未找到 .lua: 模式")
                return None
            
            # 步骤3: 提取文件路径
            file_path = clean_line[:lua_pos + 4].strip()
            rest_of_line = clean_line[lua_pos + 5:]  # .lua: 之后的部分
            
            logger.debug(f"文件路径: {file_path}")
            logger.debug(f"剩余: {rest_of_line[:120]}")
            
            # 步骤4: 解析两种可能的格式
            # 格式A (新版): "22:37 [Error] Undefined global `X`. (code)"
            # 格式B (传统): "22:37: error: Undefined global `X`"
            
            # 尝试格式A: 行:列 [级别] 消息
            match = re.match(r'(\d+):(\d+)\s*\[(\w+)\]\s*(.+)', rest_of_line)
            if match:
                line_num = int(match.group(1))
                col_num = int(match.group(2))
                level = match.group(3).strip()
                message = match.group(4).strip()
                logger.debug(f"[格式A] 行={line_num}, 列={col_num}, 级别={level}")
            else:
                # 尝试格式B: 行:列: 级别: 消息
                match = re.match(r'(\d+):(\d+):\s*(\w+):\s*(.+)', rest_of_line)
                if match:
                    line_num = int(match.group(1))
                    col_num = int(match.group(2))
                    level = match.group(3).strip()
                    message = match.group(4).strip()
                    logger.debug(f"[格式B] 行={line_num}, 列={col_num}, 级别={level}")
                else:
                    logger.debug(f"格式不匹配: {rest_of_line[:100]}")
                    return None
            
            # 步骤5: 映射严重级别
            level_lower = level.lower()
            if level_lower == 'error':
                severity = 1
            elif level_lower == 'warning':
                severity = 2
            elif level_lower == 'info' or level_lower == 'information':
                severity = 3
            elif level_lower == 'hint':
                severity = 4
            else:
                severity = 1  # 默认错误
            
            # 步骤6: 提取错误码（圆括号或方括号中的内容）
            code = ''
            code_match = re.search(r'\(([^)]+)\)$', message)
            if not code_match:
                code_match = re.search(r'\[([^\]]+)\]$', message)
            if code_match:
                code = code_match.group(1)
                message = message[:code_match.start()].strip()
            
            result = {
                'file': file_path,
                'line': line_num,
                'column': col_num,
                'severity': severity,
                'message': message,
                'code': code
            }
            logger.debug(f"✓ 成功解析: {result}")
            return result
            
        except Exception as e:
            logger.debug(f"✗ 解析异常: {line[:100]} - {e}")

            logger.debug(traceback.format_exc())
            return None
    
    def start_watch_mode(self):
        """持续监视模式（原有实现）"""
        if not WATCHDOG_AVAILABLE:
            logger.error("监视模式需要 watchdog 库")
            logger.error("请安装: pip install watchdog>=3.0.0")
            sys.exit(1)
        
        logger.info("正在启动 Lua LSP 服务器...")
        self.running = True

        # 启动 emmylua_ls 进程（首次启动失败则退出）
        try:
            self._start_lsp_process()
        except Exception as e:
            logger.error(f"首次启动 emmylua_ls 失败: {e}")
            sys.exit(1)

        # 初始化 LSP 连接
        self._initialize_lsp()

        # 启动 HTTP RPC 代理（如果配置了端口）
        if self.http_port > 0:
            self.start_http_server(self.http_port)

        # 执行初始检查
        self._check_all_files()

        # 启动文件监视器
        self._start_file_watcher()

        logger.info("Lua LSP 服务器已启动")
    
    def _kill_process_tree(self, pid: int):
        """杀死进程及其子进程"""
        try:
            if os.name == 'nt':
                # Windows: taskkill /T 杀死进程树
                subprocess.run(
                    ['taskkill', '/F', '/T', '/PID', str(pid)],
                    capture_output=True,
                    timeout=5
                )
            else:
                # Linux/Mac: 使用进程组 ID 杀死整个进程树
                # 因为我们用 start_new_session=True 启动，pid 就是 pgid
                import signal as sig
                try:
                    os.killpg(pid, sig.SIGTERM)  # 先尝试优雅终止
                    time.sleep(0.3)
                    os.killpg(pid, sig.SIGKILL)  # 强制杀死
                except ProcessLookupError:
                    pass  # 进程已退出
        except Exception as e:
            logger.debug(f"杀死进程 {pid} 时出错: {e}")

    def _start_lsp_process(self):
        """启动 emmylua_ls 进程"""
        if self.lsp_process and self.lsp_process.poll() is None:
            logger.info(f"清理旧的 LSP 进程 (PID: {self.lsp_process.pid})")
            self._kill_process_tree(self.lsp_process.pid)
            self.lsp_process = None
            time.sleep(0.3)

        try:
            lsp_args = [
                self.lsp_executable,
                '--communication', 'stdio',
                '--log-level', 'warn',
                '--log-path', 'none',
                '--resources-path', 'none',
            ]
            logger.info(f"LSP 启动参数: {' '.join(lsp_args)}")

            popen_kwargs = {
                'stdin': subprocess.PIPE,
                'stdout': subprocess.PIPE,
                'stderr': subprocess.PIPE,
                'bufsize': 0,
            }
            if os.name != 'nt':
                popen_kwargs['start_new_session'] = True

            self.lsp_process = subprocess.Popen(lsp_args, **popen_kwargs)

            threading.Thread(target=self._read_lsp_output, daemon=True).start()
            threading.Thread(target=self._read_lsp_stderr, daemon=True).start()

            logger.info("emmylua_ls 进程已启动")
            
            # 等待一小段时间，检查进程是否立即退出
            time.sleep(0.5)
            if self.lsp_process.poll() is not None:
                raise RuntimeError(f"emmylua_ls 进程立即退出，退出码: {self.lsp_process.returncode}")
        except Exception as e:
            logger.error(f"启动 emmylua_ls 失败: {e}")
            raise
    
    def _read_lsp_stderr(self):
        """读取 LSP stderr 输出"""
        while self.running and self.lsp_process:
            try:
                line = self.lsp_process.stderr.readline()
                if not line:
                    break
                stderr_text = line.decode('utf-8', errors='replace').strip()
                if stderr_text:
                    logger.info(f"emmylua_ls: {stderr_text}")
            except Exception as e:
                logger.error(f"读取 LSP stderr 失败: {e}")
                break
    
    def _initialize_lsp(self):
        """初始化 LSP 连接"""
        init_params = {
            "processId": os.getpid(),
            "rootUri": self.lua_scripts_dir.as_uri(),
            "capabilities": {
                "textDocument": {
                    "publishDiagnostics": {}
                },
                "workspace": {
                    "configuration": True,
                    "didChangeWatchedFiles": {
                        "dynamicRegistration": True
                    }
                }
            },
            "workspaceFolders": [{
                "uri": self.lua_scripts_dir.as_uri(),
                "name": "LuaScripts"
            }]
        }

        # 允许外部 override 的 $initParams 替换，动态字段强制回写
        override = self._load_override_config()
        if '$initParams' in override:
            init_params = override['$initParams']
            logger.info("init_params 已被 $initParams 替换")

        # 动态字段始终用运行时值
        init_params['processId'] = os.getpid()
        init_params['rootUri'] = self.lua_scripts_dir.as_uri()
        init_params['workspaceFolders'] = [{
            "uri": self.lua_scripts_dir.as_uri(),
            "name": "LuaScripts"
        }]

        self._send_message({
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "initialize",
            "params": init_params
        })
        time.sleep(2)

        initialized_notification = {
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": {}
        }

        self._send_message(initialized_notification)
        logger.info("LSP 连接已初始化（配置通过 workspace/configuration 注入）")
    
    def _read_lsp_output(self):
        """读取 LSP 输出"""
        buffer = b''
        
        while self.running and self.lsp_process:
            try:
                chunk = self.lsp_process.stdout.read(4096)
                if not chunk:
                    break
                
                buffer += chunk
                
                # 尝试解析消息
                while True:
                    # 查找完整消息
                    header_end = buffer.find(b'\r\n\r\n')
                    if header_end == -1:
                        break
                    
                    # 解析 Content-Length
                    header = buffer[:header_end].decode('utf-8')
                    content_length = None
                    for line in header.split('\r\n'):
                        if line.startswith('Content-Length:'):
                            content_length = int(line.split(':')[1].strip())
                            break
                    
                    if content_length is None:
                        buffer = buffer[header_end + 4:]
                        continue
                    
                    # 检查是否有完整的消息体
                    body_start = header_end + 4
                    if len(buffer) < body_start + content_length:
                        break
                    
                    # 提取并处理消息
                    body = buffer[body_start:body_start + content_length]
                    message = json.loads(body.decode('utf-8'))
                    self._handle_message(message)
                    
                    # 移除已处理的消息
                    buffer = buffer[body_start + content_length:]
                    
            except Exception as e:
                logger.error(f"读取 LSP 输出时出错: {e}")
                break

        # emmylua_ls 意外退出时自动重启
        if self.running and self.lsp_process and self.lsp_process.poll() is not None:
            should_restart = False
            with self.lock:
                if not self.running or (self.lsp_process and self.lsp_process.poll() is None):
                    return
                self._restart_count += 1
                if self._restart_count > 3:
                    logger.error("emmylua_ls 连续崩溃超过 3 次，退出进程")
                    os._exit(1)
                exit_code = self.lsp_process.returncode
                logger.warning(f"emmylua_ls 意外退出 (exit={exit_code})，3 秒后重启 ({self._restart_count}/3)...")
                should_restart = True

            if should_restart:
                time.sleep(3)
                if not self.running:
                    return
                try:
                    self._start_lsp_process()
                    self._initialize_lsp()
                    self._check_all_files()
                    self._restart_count = 0
                    logger.info("emmylua_ls 已自动重启")
                except Exception as e:
                    logger.error(f"自动重启失败: {e}")
    
    def _handle_message(self, message: dict):
        """处理 LSP 消息"""
        msg_id = message.get('id')

        # 检查是否是我们等待的响应（有 id 且有 result 或 error）
        if msg_id is not None and ('result' in message or 'error' in message):
            with self._pending_lock:
                if msg_id in self._pending_requests:
                    self._pending_requests[msg_id]['result'] = message
                    self._pending_requests[msg_id]['event'].set()
                    logger.debug(f"收到响应: id={msg_id}")
                    return

        method = message.get('method')

        # emmylua_ls 注册文件监视模式，解析 glob 并确认
        if method == 'client/registerCapability' and msg_id is not None:
            for reg in message.get('params', {}).get('registrations', []):
                if reg.get('method') == 'workspace/didChangeWatchedFiles':
                    watchers = reg.get('registerOptions', {}).get('watchers', [])
                    self._watch_patterns = [w.get('globPattern', '') for w in watchers
                                            if isinstance(w.get('globPattern'), str)]
                    logger.info(f"client/registerCapability: {self._watch_patterns}")
            self._send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": None
            })
            return

        # emmylua_ls 请求 workspace/configuration 时，返回 override 配置
        if method == 'workspace/configuration' and msg_id is not None:
            items = message.get('params', {}).get('items', [])
            logger.info(f"workspace/configuration 请求: items={json.dumps(items, ensure_ascii=False)}")
            override = self._load_override_config()
            override['workspace'] = self._resolve_workspace_paths()
            # 读项目配置的 severity 值，全转小写合入 override（修复旧 LuaLS 大写问题）
            self._normalize_project_severity(override)
            # 剔除 $ 开头的扩展字段，不发给 emmylua_ls
            override = {k: v for k, v in override.items() if not k.startswith('$')}
            result = [override] * len(items) if items else [override]
            self._send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": result
            })
            logger.info(f"workspace/configuration 已响应 override 配置 ({len(items)} items)")
            logger.info(f"workspace/configuration payload: {json.dumps(result[0], ensure_ascii=False)[:500]}")
            return

        # 处理 LSP 主动推送的通知
        if method == 'textDocument/publishDiagnostics':
            self._handle_diagnostics(message['params'])
        elif 'error' in message:
            logger.error(f"LSP 错误: {message['error']}")

    # ========== HTTP RPC 代理功能 ==========

    def forward_request(self, method: str, params: dict, timeout: float = 30.0) -> dict:
        """转发 LSP 请求并等待响应

        Args:
            method: LSP 方法名
            params: 请求参数
            timeout: 超时时间（秒）

        Returns:
            {"ok": True, "result": ...} 或 {"ok": False, "error": ...}
        """
        logger.debug(f"forward_request: method={method}, is_notification={method in LSP_NOTIFICATION_METHODS}")
        try:
            if method in LSP_NOTIFICATION_METHODS:
                # Notification: 发送后直接返回
                logger.debug(f"forward_request: sending notification...")
                self._send_message({
                    'jsonrpc': '2.0',
                    'method': method,
                    'params': params
                })
                logger.debug(f"forward_request: notification sent")
                return {'ok': True}
            else:
                # Request: 需要等待响应
                internal_id = self._next_id()
                event = threading.Event()

                with self._pending_lock:
                    self._pending_requests[internal_id] = {
                        'event': event,
                        'result': None
                    }

                # 发送请求
                self._send_message({
                    'jsonrpc': '2.0',
                    'id': internal_id,
                    'method': method,
                    'params': params
                })

                # 等待响应
                if event.wait(timeout):
                    with self._pending_lock:
                        response = self._pending_requests.pop(internal_id)['result']

                    if 'error' in response:
                        return {'ok': False, 'error': response['error']}
                    else:
                        return {'ok': True, 'result': response.get('result')}
                else:
                    # 超时，清理
                    with self._pending_lock:
                        self._pending_requests.pop(internal_id, None)
                    return {'ok': False, 'error': f'Timeout after {timeout}s'}

        except Exception as e:
            logger.error(f"forward_request 失败: {e}")
            return {'ok': False, 'error': str(e)}

    def start_http_server(self, port: int) -> bool:
        """启动 HTTP RPC 代理服务器

        Returns:
            True 如果启动成功，否则抛出异常
        """
        self.http_port = port

        # 创建 Handler 类，绑定 lsp_server 实例
        lsp_server = self

        class RPCProxyHandler(BaseHTTPRequestHandler):
            """HTTP RPC 代理处理器"""

            def do_GET(self):
                """GET 端点"""
                if self.path == '/health':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(b'OK')
                else:
                    self.send_error(404)

            def do_POST(self):
                start_time = time.time()
                logger.info(f"[HTTP] do_POST 开始处理 path={self.path}")

                if self.path != '/rpc':
                    self.send_error(404, 'Not Found')
                    return

                try:
                    # 读取请求体
                    content_length = int(self.headers.get('Content-Length', 0))
                    logger.debug(f"[HTTP] 读取 body, Content-Length={content_length}")
                    body = self.rfile.read(content_length)
                    logger.debug(f"[HTTP] body 读取完成, 耗时 {time.time() - start_time:.3f}s")
                    request = json.loads(body.decode('utf-8'))
                    logger.info(f"RPC 收到请求: method={request.get('method')}, size={len(body)} bytes")

                    # 提取 method 和 params
                    method = request.get('method')
                    params = request.get('params', {})

                    # 提取分页参数（不影响 LSP 请求）
                    page = request.get('page', 1)
                    page_size = request.get('page_size', 20)
                    page_max_bytes = request.get('page_max_bytes', 16000)

                    if not method:
                        self._send_json({'ok': False, 'error': 'Missing method'})
                        return

                    # 模拟 textDocument/diagnostic（从内存诊断缓存返回）
                    if method == 'textDocument/diagnostic':
                        result = self._handle_diagnostic_request(params, page, page_size, page_max_bytes)
                        self._send_json(result)
                        return

                    # 转发到 LSP
                    logger.info(f"RPC 转发: {method}")
                    result = lsp_server.forward_request(method, params)

                    # 应用分页
                    result = paginate_result(result, page, page_size, page_max_bytes)

                    result_str = json.dumps(result, ensure_ascii=False)
                    logger.info(f"RPC 响应: ok={result.get('ok')}, size={len(result_str)} bytes")
                    self._send_json(result)

                except json.JSONDecodeError as e:
                    self._send_json({'ok': False, 'error': f'Invalid JSON: {e}'})
                except Exception as e:
                    logger.error(f"RPC 处理错误: {e}")
                    self._send_json({'ok': False, 'error': str(e)})

            def _handle_diagnostic_request(self, params: dict, page: int, page_size: int, page_max_bytes: int) -> dict:
                """处理 textDocument/diagnostic 请求（模拟实现）

                标准 LSP 参数:
                    - textDocument.uri: 单文件诊断（标准 LSP 行为）

                扩展参数:
                    - severity: 返回该级别及更严重的诊断 1=Error, 2=Warning, 3=Info, 4=Hint（默认 2）
                    - summaryOnly: 只返回摘要

                无 textDocument.uri 时返回整个工作区的诊断（扩展行为）
                """
                severity_threshold = params.get('severity', 2)  # 默认 warning + error
                summary_only = params.get('summaryOnly', False)

                # 解析单文件 URI（标准 LSP 参数）
                text_document = params.get('textDocument', {})
                target_uri = text_document.get('uri') if isinstance(text_document, dict) else None
                target_path = None
                if target_uri:
                    # 复用 _uri_to_path 的逻辑，确保路径格式一致
                    target_path = lsp_server._uri_to_path(target_uri)

                # 线程安全：先获取快照
                with lsp_server.lock:
                    diagnostics_snapshot = dict(lsp_server.diagnostics)

                # 单文件模式：只返回指定文件的诊断
                if target_path:
                    file_diags = diagnostics_snapshot.get(target_path, [])
                    filtered_diags = [d for d in file_diags if d.get('severity', 4) <= severity_threshold]
                    return {
                        'ok': True,
                        'result': {
                            'kind': 'full',
                            'items': filtered_diags
                        }
                    }

                # 工作区模式：返回所有文件的诊断（扩展行为）
                # 计算公共路径前缀
                all_paths = list(diagnostics_snapshot.keys())
                common_prefix = ''
                if all_paths:
                    try:
                        common_prefix = os.path.commonpath(all_paths)
                        if not os.path.isdir(common_prefix):
                            common_prefix = os.path.dirname(common_prefix)
                    except ValueError:
                        common_prefix = ''

                # 扁平化 + 过滤严重程度 + 剥离路径前缀
                flat_diags = []
                severity_count = {1: 0, 2: 0, 3: 0, 4: 0}
                for file_path, diags in diagnostics_snapshot.items():
                    rel_path = os.path.relpath(file_path, common_prefix) if common_prefix else file_path
                    for d in diags:
                        sev = d.get('severity', 4)
                        severity_count[sev] = severity_count.get(sev, 0) + 1
                        if sev <= severity_threshold:
                            flat_item = {'file': rel_path}
                            flat_item.update(d)
                            flat_diags.append(flat_item)

                # 构建 summary
                summary = {
                    'files': len(diagnostics_snapshot),
                    'total': sum(len(d) for d in diagnostics_snapshot.values()),
                    'errors': severity_count.get(1, 0),
                    'warnings': severity_count.get(2, 0),
                    'info': severity_count.get(3, 0),
                    'hints': severity_count.get(4, 0)
                }

                if summary_only:
                    logger.info(f"诊断摘要: {summary['files']} 文件, {summary['total']} 问题")
                    return {'ok': True, 'result': {'kind': 'full', 'summary': summary, 'items': []}}

                # 应用分页
                result = paginate_result(
                    {'ok': True, 'result': flat_diags},
                    page, page_size, page_max_bytes
                )

                # 统一响应格式：{ ok, pagination?, result: { kind, summary, items } }
                response = {'ok': True}
                if 'pagination' in result:
                    response['pagination'] = result['pagination']
                response['result'] = {
                    'kind': 'full',
                    'summary': summary,
                    'items': result.get('result', flat_diags)
                }

                logger.info(f"诊断查询: {summary['files']} 文件, {len(response['result']['items'])} 条")
                return response

            def _send_json(self, data: dict):
                body = json.dumps(data, ensure_ascii=False).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', len(body))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                # 使用我们的 logger
                logger.debug(f"HTTP: {format % args}")

        # 启动 HTTP 服务器（使用 ThreadingHTTPServer 支持并发）
        try:
            server = ThreadingHTTPServer(('127.0.0.1', port), RPCProxyHandler)
            server.daemon_threads = True  # 请求处理线程设为 daemon
            logger.info(f"HTTP RPC 代理已启动: http://127.0.0.1:{port}/rpc")

            def serve():
                logger.debug("HTTP 服务线程已启动")
                server.serve_forever()

            http_thread = threading.Thread(target=serve, daemon=True, name="HTTP-RPC-Server")
            http_thread.start()
            logger.debug(f"HTTP 线程状态: alive={http_thread.is_alive()}")
            return True
        except OSError as e:
            # 端口被占用等系统错误
            logger.error(f"启动 HTTP 服务器失败 (端口 {port}): {e}")
            raise RuntimeError(f"HTTP 服务器启动失败: {e}") from e
        except Exception as e:
            logger.error(f"启动 HTTP 服务器失败: {e}")
            raise RuntimeError(f"HTTP 服务器启动失败: {e}") from e

    def _handle_diagnostics(self, params: dict):
        """处理诊断信息（watch 模式）"""
        uri = params['uri']
        diagnostics = params['diagnostics']

        # 转换 URI 到文件路径
        file_path = self._uri_to_path(uri)
        file_name = os.path.basename(file_path)

        with self.lock:
            if diagnostics:
                # 清空该文件的旧诊断
                self.diagnostics[file_path] = []
                
                # 显示文件头部
                if self.use_color:
                    logger.info(f"\n{Color.MAGENTA}{'━'*60}{Color.RESET}")
                    logger.info(f"{Color.BOLD}📄 {file_name}{Color.RESET} - 发现 {Color.RED}{len(diagnostics)}{Color.RESET} 个问题")
                    logger.info(f"{Color.MAGENTA}{'━'*60}{Color.RESET}")
                else:
                    logger.info(f"\n{'━'*60}")
                    logger.info(f"📄 {file_name} - 发现 {len(diagnostics)} 个问题")
                    logger.info(f"{'━'*60}")
                
                # 添加每个诊断（使用统一方法）
                for diag in diagnostics:
                    self._add_diagnostic_to_store(file_path, diag, show_output=True)
            else:
                # 没有问题，删除该文件的诊断
                if file_path in self.diagnostics:
                    del self.diagnostics[file_path]
                if self.use_color:
                    logger.info(f"{Color.GREEN}✓{Color.RESET} {file_name} - 没有问题")
                else:
                    logger.info(f"✓ {file_name} - 没有问题")
            
            # 保存诊断结果到 .log 文件
            self._save_diagnostics()
            self._save_errors_only()
    
    def _save_diagnostics(self):
        """保存诊断结果到 .log 文件（单行格式，包含所有级别）"""
        try:
            with open(self.output_file, 'w', encoding='utf-8') as f:
                # 统计信息
                error_count = sum(1 for diags in self.diagnostics.values() 
                                for d in diags if d.get('severity') == 1)
                warning_count = sum(1 for diags in self.diagnostics.values() 
                                  for d in diags if d.get('severity') == 2)
                info_count = sum(1 for diags in self.diagnostics.values() 
                               for d in diags if d.get('severity') == 3)
                hint_count = sum(1 for diags in self.diagnostics.values() 
                               for d in diags if d.get('severity') == 4)
                
                total_issues = error_count + warning_count + info_count + hint_count
                
                # 头部（第一行写明 .emmylua 位置）
                f.write(f"Lua Diagnostics | Errors: {error_count} | Warnings: {warning_count} | ")
                f.write(f"EmmyLua Types: {self.emmylua_dir}\n")
                f.write(f"Info: {info_count} | Hints: {hint_count} | ")
                f.write(f"Total: {total_issues} | Time: {time.strftime('%Y-%m-%d %H:%M:%S')} | ")
                f.write(f"Dir: {self.lua_scripts_dir}\n")
                f.write("---\n")
                
                if total_issues == 0:
                    f.write("✅ No issues found\n")
                else:
                    # 单行格式：LEVEL | 文件:行:列 | 信息 [错误码]
                    # 严重级别映射
                    severity_map = {1: "ERROR", 2: "WARN ", 3: "INFO ", 4: "HINT "}
                    
                    # 收集所有诊断并按严重级别排序
                    all_diags = []
                    for file_path, diags in sorted(self.diagnostics.items()):
                        file_name = os.path.basename(file_path)
                        for diag in diags:
                            all_diags.append((file_name, diag))
                    
                    # 按严重级别排序（错误优先）
                    all_diags.sort(key=lambda x: x[1].get('severity', 1))
                    
                    # 输出每一行诊断
                    for file_name, diag in all_diags:
                        severity = diag.get('severity', 1)
                        level = severity_map.get(severity, "UNKN ")
                        
                        range_info = diag.get('range', {})
                        start = range_info.get('start', {})
                        line = start.get('line', 0) + 1
                        column = start.get('character', 0) + 1
                        
                        # 清理消息（只取第一行）
                        message = diag.get('message', '').split('\n')[0].strip()
                        
                        code = diag.get('code', '')
                        code_str = f"[{code}]" if code else ""
                        
                        # 格式：LEVEL | 文件:行:列 | 信息 [错误码]
                        f.write(f"{level} | {file_name}:{line}:{column} | {message} {code_str}\n".strip() + "\n")
            
            logger.debug(f"诊断结果已保存到 {self.output_file}")
        except Exception as e:
            logger.error(f"保存诊断结果失败: {e}")
    
    def _save_errors_only(self):
        """只保存错误到 .log 文件（单行格式）"""
        try:
            with open(self.errors_only_file, 'w', encoding='utf-8') as f:
                # 统计错误数量
                error_count = sum(1 for diags in self.diagnostics.values() 
                                for d in diags if d.get('severity') == 1)
                
                # 头部
                f.write(f"Lua Errors: {error_count} | Dir: {self.lua_scripts_dir} | Time: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write(f"EmmyLua Types: {self.emmylua_dir}\n")
                f.write("---\n")
                
                if error_count == 0:
                    f.write("✅ No errors\n")
                else:
                    # 单行格式：ERROR | 文件:行:列 | 错误信息 [错误码]
                    for file_path, diags in sorted(self.diagnostics.items()):
                        errors = [d for d in diags if d.get('severity') == 1]
                        if errors:
                            file_name = os.path.basename(file_path)
                            
                            for err in errors:
                                range_info = err.get('range', {})
                                start = range_info.get('start', {})
                                line = start.get('line', 0) + 1
                                column = start.get('character', 0) + 1
                                
                                # 清理重复的错误消息
                                message = err.get('message', '').split('\n')[0].strip()
                                
                                code = err.get('code', '')
                                code_str = f"[{code}]" if code else ""
                                
                                # 格式：ERROR | 文件:行:列 | 错误信息 [错误码]
                                f.write(f"ERROR | {file_name}:{line}:{column} | {message} {code_str}\n".strip() + "\n")
            
            logger.debug(f"错误报告已保存到 {self.errors_only_file}")
        except Exception as e:
            logger.error(f"保存错误报告失败: {e}")
    
    def _send_message(self, message: dict):
        """发送消息到 LSP"""
        if not self.lsp_process or not self.lsp_process.stdin:
            return

        if self.lsp_process.poll() is not None:
            return

        try:
            encoded = LSPProtocol.encode_message(message)
            with self._write_lock:
                self.lsp_process.stdin.write(encoded)
                self.lsp_process.stdin.flush()
        except BrokenPipeError:
            logger.warning("LSP 进程已断开连接 (Broken pipe)")
        except Exception as e:
            logger.error(f"发送消息失败: {e}")

    def close_file(self, file_path: str):
        """关闭文件并释放 LSP 资源"""
        file_path = str(Path(file_path).resolve())

        if file_path not in self.opened_files:
            return

        uri = Path(file_path).as_uri()

        # 发送 didClose 通知
        did_close = {
            "jsonrpc": "2.0",
            "method": "textDocument/didClose",
            "params": {
                "textDocument": {"uri": uri}
            }
        }
        self._send_message(did_close)

        # 从缓存中移除
        del self.opened_files[file_path]

        # 清理诊断信息
        with self.lock:
            if file_path in self.diagnostics:
                del self.diagnostics[file_path]

        logger.debug(f"已关闭文件: {Path(file_path).name}")

    def check_file(self, file_path: str):
        """检查单个文件"""
        file_path = str(Path(file_path).resolve())

        if not Path(file_path).exists():
            # 文件已删除，发送 didClose 并清理
            if file_path in self.opened_files:
                self.close_file(file_path)
            return

        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()

            uri = Path(file_path).as_uri()

            if file_path in self.opened_files:
                # 文件已打开，发送 didChange + 递增版本号
                self.opened_files[file_path] += 1
                version = self.opened_files[file_path]

                did_change = {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didChange",
                    "params": {
                        "textDocument": {
                            "uri": uri,
                            "version": version
                        },
                        "contentChanges": [
                            {"text": content}  # 全量更新
                        ]
                    }
                }
                self._send_message(did_change)

                # 发送 didSave 通知，触发工作区级别的诊断（包括依赖文件）
                did_save = {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didSave",
                    "params": {
                        "textDocument": {"uri": uri},
                        "text": content
                    }
                }
                self._send_message(did_save)
                logger.debug(f"已发送变更通知: {Path(file_path).name} (v{version})")
            else:
                # 首次打开，发送 didOpen
                self.opened_files[file_path] = 1

                did_open = {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didOpen",
                    "params": {
                        "textDocument": {
                            "uri": uri,
                            "languageId": "lua",
                            "version": 1,
                            "text": content
                        }
                    }
                }
                self._send_message(did_open)

                # 同时发送 didSave 触发完整的工作区诊断
                did_save = {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didSave",
                    "params": {
                        "textDocument": {"uri": uri},
                        "text": content
                    }
                }
                self._send_message(did_save)
                logger.debug(f"已发送打开通知: {Path(file_path).name} (v1)")

        except Exception as e:
            logger.error(f"检查文件 {file_path} 失败: {e}")
    
    def _check_all_files(self):
        """检查所有 Lua 文件"""
        if self.use_color:
            logger.info(f"\n{Color.CYAN}{'='*60}{Color.RESET}")
            logger.info(f"{Color.BOLD}🔍 开始扫描 Lua 文件...{Color.RESET}")
            logger.info(f"{Color.CYAN}{'='*60}{Color.RESET}")
        else:
            logger.info(f"\n{'='*60}")
            logger.info(f"🔍 开始扫描 Lua 文件...")
            logger.info(f"{'='*60}")
        
        lua_files = list(self.lua_scripts_dir.rglob('*.lua'))
        logger.info(f"找到 {len(lua_files)} 个 Lua 文件")
        
        for lua_file in lua_files:
            self.check_file(str(lua_file))
            time.sleep(0.1)  # 避免过快发送请求
        
        # 等待一段时间让诊断结果返回
        time.sleep(2)
        
        # 输出摘要
        with self.lock:
            summary = DiagnosticFormatter.format_summary(self.diagnostics, use_color=self.use_color)
            logger.info(summary)
        
        if self.use_color:
            logger.info(f"{Color.GREEN}✓ 初始检查完成{Color.RESET}")
        else:
            logger.info("✓ 初始检查完成")
    
    def _start_file_watcher(self):
        """启动文件监视器"""
        event_handler = LuaFileWatcher(self)
        observer = Observer()
        observer.schedule(event_handler, str(self.lua_scripts_dir), recursive=True)
        observer.start()
        logger.info("文件监视器已启动")
        
        try:
            while self.running:
                time.sleep(1)
        finally:
            observer.stop()
            observer.join()
    
    def stop(self):
        """停止服务器"""
        if not self.running:
            return
        self.running = False
        logger.info("正在停止 Lua LSP 服务器...")

        if self.lsp_process:
            pid = self.lsp_process.pid
            logger.info(f"正在清理 LSP 进程 (PID: {pid})...")

            try:
                # 尝试优雅退出
                shutdown_request = {
                    "jsonrpc": "2.0",
                    "id": self._next_id(),
                    "method": "shutdown",
                    "params": None
                }
                self._send_message(shutdown_request)
                time.sleep(0.2)

                exit_notification = {
                    "jsonrpc": "2.0",
                    "method": "exit",
                    "params": None
                }
                self._send_message(exit_notification)

                # 等待进程退出
                try:
                    self.lsp_process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            except Exception:
                pass

            # 如果还没退出，强制杀死进程树
            if self.lsp_process.poll() is None:
                logger.info(f"强制终止 LSP 进程树 (PID: {pid})")
                self._kill_process_tree(pid)

            self.lsp_process = None
            logger.info("LSP 进程已清理")
        
        logger.info("Lua LSP 服务器已停止")
    
    def _next_id(self) -> int:
        return next(self._id_counter)


def main():
    # 解析命令行参数
    parser = argparse.ArgumentParser(description='Lua LSP 服务器 - 监视并检查 Lua 文件')
    parser.add_argument('--path', '-p', 
                       help='要监视的 Lua 脚本目录路径',
                       default=None)
    parser.add_argument('--output-dir', '-d',
                       help='日志文件输出目录（默认为脚本所在目录）',
                       default=None)
    parser.add_argument('--mode', '-m',
                       help='运行模式：watch(持续监视) 或 check(单次检查)',
                       choices=['watch', 'check'],
                       default='watch')
    parser.add_argument('--configpath', '-c',
                       help='指定 .luarc.json 配置文件路径',
                       default=None)
    parser.add_argument('--http-port',
                       help='HTTP RPC 代理端口（默认禁用，传入端口号如 9527 启用）',
                       type=int,
                       default=0)
    parser.add_argument('--enable-system-log',
                       help='启用系统日志文件 lua_lsp.log（写到 --output-dir 目录）',
                       action='store_true')
    parser.add_argument('--ls-path',
                       help='emmylua_ls 可执行文件路径（默认从 PATH 查找）',
                       default=None)
    parser.add_argument('--debug',
                       help='启用调试模式（显示详细日志）',
                       action='store_true')
    parser.add_argument('--quiet', '-q',
                       help='静默模式（仅显示错误和警告，适合后台运行）',
                       action='store_true')
    
    args = parser.parse_args()
    
    # 设置日志级别（只改 stdout handler，不影响后续添加的文件 handler）
    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)
        for handler in logging.getLogger().handlers:
            handler.setLevel(logging.DEBUG)
    elif args.quiet:
        logging.getLogger().setLevel(logging.DEBUG)  # root 保持最低，由 handler 各自过滤
        for handler in logging.getLogger().handlers:
            handler.setLevel(logging.WARNING)  # stdout 只输出 warning+
    
    # 配置路径
    script_dir = Path(__file__).parent.resolve()
    
    # 确定监视目录
    if args.path:
        lua_scripts_dir = Path(args.path).resolve()
    else:
        # 默认路径：相对于脚本位置（tools/lua-tools/lua_lsp -> 项目根目录）
        lua_scripts_dir = script_dir.parent.parent.parent / "engine" / "bin" / "Data" / "LuaScripts"
    
    if not lua_scripts_dir.exists():
        logger.error(f"LuaScripts 目录不存在: {lua_scripts_dir}")
        sys.exit(1)
    
    # 确定输出目录
    if args.output_dir:
        output_dir = Path(args.output_dir).resolve()
    else:
        # 默认输出到脚本所在目录
        output_dir = script_dir
    
    # 创建输出目录
    output_dir.mkdir(parents=True, exist_ok=True)

    # 追加文件日志到 output_dir
    # 优先级：--enable-system-log CLI 参数 > .emmyrc.override.json 的 $enableSystemLog
    override_file = script_dir / '.emmyrc.override.json'
    override_enable_log = False
    if override_file.exists():
        try:
            with open(override_file, 'r', encoding='utf-8-sig') as f:
                override_enable_log = json.load(f).get('$enableSystemLog', False)
        except Exception:
            pass
    if args.enable_system_log or override_enable_log:
        class StripAnsiFormatter(logging.Formatter):
            _ansi_re = re.compile(r'\x1b\[[0-9;]*m')
            def format(self, record):
                msg = super().format(record)
                return self._ansi_re.sub('', msg)

        file_handler = logging.FileHandler(str(output_dir / "lua_lsp.log"), mode='w', encoding='utf-8')
        file_handler.setFormatter(StripAnsiFormatter('%(asctime)s - %(process)d - %(levelname)s - %(message)s'))
        logging.getLogger().addHandler(file_handler)

    # 固定的日志文件名
    output_file = str(output_dir / "lua_diagnostics.log")
    errors_file = str(output_dir / "lua_errors.log")
    
    # 创建并启动服务器
    server = LuaLSPServer(
        str(lua_scripts_dir),
        output_file=output_file,
        errors_only_file=errors_file,
        mode=args.mode,
        config_path=args.configpath,
        lsp_path=args.ls_path
    )

    # 设置 HTTP 端口（仅 watch 模式）
    if args.mode == 'watch':
        server.http_port = args.http_port

        # 注册退出清理（确保关闭控制台时也能清理）
        atexit.register(server.stop)

        # 信号处理（Windows 和 Unix）
        def signal_handler(signum, frame):
            logger.info(f"收到信号 {signum}，正在清理...")
            server.stop()
            sys.exit(0)

        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)
        if hasattr(signal, 'SIGBREAK'):  # Windows only
            signal.signal(signal.SIGBREAK, signal_handler)

    # 根据模式调整日志头部
    mode_display = "持续监视模式" if args.mode == "watch" else "单次检查模式"

    logger.info(f"\n{Color.BOLD}{Color.GREEN}{'='*60}{Color.RESET}")
    logger.info(f"{Color.BOLD}{Color.GREEN} Lua LSP 服务器 v2.0.0 - EmmyLuaLS ({mode_display}){Color.RESET}")
    logger.info(f"{Color.BOLD}{Color.GREEN}{'='*60}{Color.RESET}")
    logger.info(f"监视目录: {Color.CYAN}{lua_scripts_dir}{Color.RESET}")
    logger.info(f"EmmyLua:  {Color.CYAN}{server.emmylua_dir}{Color.RESET}")
    logger.info(f"完整报告: {Color.CYAN}{output_file}{Color.RESET}")
    logger.info(f"错误报告: {Color.CYAN}{errors_file}{Color.RESET}")
    if args.mode == 'watch' and args.http_port > 0:
        logger.info(f"HTTP RPC: {Color.CYAN}http://127.0.0.1:{args.http_port}/rpc{Color.RESET}")
    logger.info(f"{Color.GREEN}{'='*60}{Color.RESET}\n")
    
    server.start()


if __name__ == "__main__":
    main()

