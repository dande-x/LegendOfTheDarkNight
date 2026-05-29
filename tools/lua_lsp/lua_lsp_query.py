#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Lua LSP Query Client
临时连接到 lua_lsp_server.py 的 HTTP RPC 代理，调用 LSP 接口
"""

import json
import sys
import argparse
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional


class LuaLSPQuery:
    """LSP 查询客户端"""

    def __init__(self, host: str = '127.0.0.1', port: int = 9527):
        self.url = f'http://{host}:{port}/rpc'

    def request(self, method: str, params: dict, timeout: float = 30.0,
                page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """发送 LSP 请求

        Args:
            method: LSP 方法名
            params: 请求参数
            timeout: 超时时间（秒）
            page: 页码（从 1 开始）
            page_size: 每页数量上限（1-100）
            page_max_bytes: 每页最大字节数

        Returns:
            {"ok": True, "result": ...} 或 {"ok": False, "error": ...}
        """
        try:
            payload = {
                'method': method,
                'params': params,
                'page': page,
                'page_size': page_size,
                'page_max_bytes': page_max_bytes
            }
            data = json.dumps(payload).encode('utf-8')

            req = urllib.request.Request(
                self.url,
                data=data,
                headers={'Content-Type': 'application/json; charset=utf-8'}
            )

            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode('utf-8'))

        except urllib.error.URLError as e:
            return {'ok': False, 'error': f'Connection failed: {e.reason}'}
        except urllib.error.HTTPError as e:
            return {'ok': False, 'error': f'HTTP {e.code}: {e.reason}'}
        except json.JSONDecodeError as e:
            return {'ok': False, 'error': f'Invalid JSON response: {e}'}
        except Exception as e:
            return {'ok': False, 'error': str(e)}

    # ========== 便捷方法 ==========

    @staticmethod
    def _uri(file_path: str) -> str:
        """转换文件路径为 URI"""
        return Path(file_path).resolve().as_uri()

    def open_file(self, file_path: str, text: str = None) -> dict:
        """打开文件 (textDocument/didOpen)

        Args:
            file_path: 文件路径
            text: 文件内容（可选，默认从文件读取）
        """
        if text is None:
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    text = f.read()
            except Exception as e:
                return {'ok': False, 'error': f'Cannot read file: {e}'}

        return self.request('textDocument/didOpen', {
            'textDocument': {
                'uri': self._uri(file_path),
                'languageId': 'lua',
                'version': 1,
                'text': text
            }
        })

    def close_file(self, file_path: str) -> dict:
        """关闭文件 (textDocument/didClose)"""
        return self.request('textDocument/didClose', {
            'textDocument': {'uri': self._uri(file_path)}
        })

    def hover(self, file_path: str, line: int, character: int) -> dict:
        """获取悬停信息 (textDocument/hover)

        Args:
            file_path: 文件路径
            line: 行号（0-based）
            character: 列号（0-based）
        """
        return self.request('textDocument/hover', {
            'textDocument': {'uri': self._uri(file_path)},
            'position': {'line': line, 'character': character}
        })

    def completion(self, file_path: str, line: int, character: int,
                   page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """获取自动补全 (textDocument/completion)"""
        return self.request('textDocument/completion', {
            'textDocument': {'uri': self._uri(file_path)},
            'position': {'line': line, 'character': character}
        }, page=page, page_size=page_size, page_max_bytes=page_max_bytes)

    def definition(self, file_path: str, line: int, character: int,
                   page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """跳转到定义 (textDocument/definition)"""
        return self.request('textDocument/definition', {
            'textDocument': {'uri': self._uri(file_path)},
            'position': {'line': line, 'character': character}
        }, page=page, page_size=page_size, page_max_bytes=page_max_bytes)

    def references(self, file_path: str, line: int, character: int,
                   include_declaration: bool = True,
                   page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """查找引用 (textDocument/references)"""
        return self.request('textDocument/references', {
            'textDocument': {'uri': self._uri(file_path)},
            'position': {'line': line, 'character': character},
            'context': {'includeDeclaration': include_declaration}
        }, page=page, page_size=page_size, page_max_bytes=page_max_bytes)

    def symbols(self, file_path: str,
                page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """获取文档符号 (textDocument/documentSymbol)"""
        return self.request('textDocument/documentSymbol', {
            'textDocument': {'uri': self._uri(file_path)}
        }, page=page, page_size=page_size, page_max_bytes=page_max_bytes)

    def workspace_symbols(self, query: str = '',
                          page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """搜索工作区符号 (workspace/symbol)"""
        return self.request('workspace/symbol', {'query': query},
                            page=page, page_size=page_size, page_max_bytes=page_max_bytes)

    def formatting(self, file_path: str, tab_size: int = 4, insert_spaces: bool = True,
                   page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """格式化文档 (textDocument/formatting)"""
        return self.request('textDocument/formatting', {
            'textDocument': {'uri': self._uri(file_path)},
            'options': {
                'tabSize': tab_size,
                'insertSpaces': insert_spaces
            }
        }, page=page, page_size=page_size, page_max_bytes=page_max_bytes)

    def rename(self, file_path: str, line: int, character: int,
               new_name: str) -> dict:
        """重命名符号 (textDocument/rename)"""
        return self.request('textDocument/rename', {
            'textDocument': {'uri': self._uri(file_path)},
            'position': {'line': line, 'character': character},
            'newName': new_name
        })

    def signature_help(self, file_path: str, line: int, character: int) -> dict:
        """获取函数签名帮助 (textDocument/signatureHelp)"""
        return self.request('textDocument/signatureHelp', {
            'textDocument': {'uri': self._uri(file_path)},
            'position': {'line': line, 'character': character}
        })

    def semantic_tokens(self, file_path: str) -> dict:
        """获取语义令牌 (textDocument/semanticTokens/full)"""
        return self.request('textDocument/semanticTokens/full', {
            'textDocument': {'uri': self._uri(file_path)}
        })

    def diagnostic(self, severity: int = 2, summary_only: bool = False,
                   page: int = 1, page_size: int = 20, page_max_bytes: int = 16000) -> dict:
        """获取诊断信息 (textDocument/diagnostic) - 模拟实现

        Args:
            severity: 返回该级别及更严重的诊断 1=Error, 2=Warning, 3=Info, 4=All（默认 2）
            summary_only: 只返回摘要
        """
        return self.request('textDocument/diagnostic', {
            'severity': severity,
            'summaryOnly': summary_only
        }, page=page, page_size=page_size, page_max_bytes=page_max_bytes)


# ========== CLI ==========

def main():
    parser = argparse.ArgumentParser(
        description='Lua LSP Query Client - 查询 Lua 代码信息',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
示例:
  %(prog)s hover test.lua 10 5
  %(prog)s completion test.lua 10 5
  %(prog)s definition test.lua 10 5
  %(prog)s symbols test.lua
  %(prog)s raw '{"method": "textDocument/hover", "params": {...}}'

分页示例:
  %(prog)s completion test.lua 10 5                    # 默认每页20条或8000字节
  %(prog)s completion test.lua 10 5 --page 2           # 第2页
  %(prog)s completion test.lua 10 5 --page-size 50     # 每页最多50条
  %(prog)s symbols test.lua --page-max-bytes 16000     # 增大字节限制
        '''
    )

    parser.add_argument('--host', default='127.0.0.1',
                        help='Server 地址 (默认: 127.0.0.1)')
    parser.add_argument('--port', type=int, default=9527,
                        help='Server 端口 (默认: 9527)')
    parser.add_argument('--timeout', type=float, default=30.0,
                        help='请求超时时间秒 (默认: 30)')

    # 分页参数作为公共父解析器，可在命令后使用
    page_parser = argparse.ArgumentParser(add_help=False)
    page_parser.add_argument('--page', type=int, default=1,
                             help='页码，从 1 开始 (默认: 1)')
    page_parser.add_argument('--page-size', type=int, default=20,
                             help='每页数量上限，1-100 (默认: 20)')
    page_parser.add_argument('--page-max-bytes', type=int, default=16000,
                             help='每页最大字节数 (默认: 16000，约 4000 tokens)')

    subparsers = parser.add_subparsers(dest='command', required=True,
                                       help='可用命令')

    # health: 健康检查
    subparsers.add_parser('health', help='检查服务器是否在线')

    # diagnostics: 诊断信息
    p = subparsers.add_parser('diagnostics', parents=[page_parser], help='获取当前诊断信息')
    p.add_argument('--errors-only', action='store_true', help='只显示错误 (等同 --severity 1)')
    p.add_argument('--severity', type=int, choices=[1, 2, 3, 4], metavar='N',
                   help='返回该级别及更严重的: 1=Error, 2=Warning, 3=Info, 4=All (默认 2)')
    p.add_argument('--summary', action='store_true', help='只显示摘要')

    # raw: 原始 JSON-RPC
    p = subparsers.add_parser('raw', parents=[page_parser], help='发送原始 JSON 请求')
    p.add_argument('json', help='JSON 字符串或 @file.json')

    # hover
    p = subparsers.add_parser('hover', help='获取悬停信息')
    p.add_argument('file', help='Lua 文件路径')
    p.add_argument('line', type=int, help='行号 (0-based)')
    p.add_argument('character', type=int, help='列号 (0-based)')

    # completion
    p = subparsers.add_parser('completion', parents=[page_parser], help='获取自动补全')
    p.add_argument('file', help='Lua 文件路径')
    p.add_argument('line', type=int, help='行号 (0-based)')
    p.add_argument('character', type=int, help='列号 (0-based)')

    # definition
    p = subparsers.add_parser('definition', parents=[page_parser], help='跳转到定义')
    p.add_argument('file', help='Lua 文件路径')
    p.add_argument('line', type=int, help='行号 (0-based)')
    p.add_argument('character', type=int, help='列号 (0-based)')

    # references
    p = subparsers.add_parser('references', parents=[page_parser], help='查找引用')
    p.add_argument('file', help='Lua 文件路径')
    p.add_argument('line', type=int, help='行号 (0-based)')
    p.add_argument('character', type=int, help='列号 (0-based)')

    # symbols
    p = subparsers.add_parser('symbols', parents=[page_parser], help='获取文档符号')
    p.add_argument('file', help='Lua 文件路径')

    # workspace-symbols
    p = subparsers.add_parser('workspace-symbols', parents=[page_parser], help='搜索工作区符号')
    p.add_argument('query', nargs='?', default='', help='搜索关键字')

    # formatting
    p = subparsers.add_parser('formatting', parents=[page_parser], help='格式化文档')
    p.add_argument('file', help='Lua 文件路径')

    # rename
    p = subparsers.add_parser('rename', help='重命名符号')
    p.add_argument('file', help='Lua 文件路径')
    p.add_argument('line', type=int, help='行号 (0-based)')
    p.add_argument('character', type=int, help='列号 (0-based)')
    p.add_argument('new_name', help='新名称')

    # signature
    p = subparsers.add_parser('signature', help='获取函数签名')
    p.add_argument('file', help='Lua 文件路径')
    p.add_argument('line', type=int, help='行号 (0-based)')
    p.add_argument('character', type=int, help='列号 (0-based)')

    args = parser.parse_args()
    client = LuaLSPQuery(args.host, args.port)
    result = None

    # 执行命令
    if args.command == 'health':
        # 健康检查 - 使用简单的 GET 请求
        try:
            health_url = f'http://{args.host}:{args.port}/health'
            req = urllib.request.Request(health_url)
            with urllib.request.urlopen(req, timeout=5) as resp:
                if resp.read() == b'OK':
                    result = {'ok': True, 'status': 'Server is running'}
                else:
                    result = {'ok': False, 'error': 'Unexpected response'}
        except Exception as e:
            result = {'ok': False, 'error': f'Server not reachable: {e}'}

    elif args.command == 'diagnostics':
        # 诊断信息 - textDocument/diagnostic（模拟实现）
        severity = 1 if args.errors_only else (args.severity or 2)
        result = client.diagnostic(
            severity=severity,
            summary_only=args.summary,
            page=args.page,
            page_size=args.page_size,
            page_max_bytes=args.page_max_bytes
        )

    elif args.command == 'raw':
        # 原始 JSON（分页参数可以在 JSON 中指定，或使用命令行参数）
        data = args.json
        if data.startswith('@'):
            with open(data[1:], 'r', encoding='utf-8') as f:
                data = f.read()
        payload = json.loads(data)
        result = client.request(
            payload.get('method', ''),
            payload.get('params', {}),
            timeout=args.timeout,
            page=payload.get('page', args.page),
            page_size=payload.get('page_size', args.page_size),
            page_max_bytes=payload.get('page_max_bytes', args.page_max_bytes)
        )

    elif args.command == 'hover':
        # 先打开文件，再查询
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.hover(args.file, args.line, args.character)

    elif args.command == 'completion':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.completion(args.file, args.line, args.character,
                                        args.page, args.page_size, args.page_max_bytes)

    elif args.command == 'definition':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.definition(args.file, args.line, args.character,
                                        args.page, args.page_size, args.page_max_bytes)

    elif args.command == 'references':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.references(args.file, args.line, args.character,
                                        page=args.page, page_size=args.page_size,
                                        page_max_bytes=args.page_max_bytes)

    elif args.command == 'symbols':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.symbols(args.file,
                                     args.page, args.page_size, args.page_max_bytes)

    elif args.command == 'workspace-symbols':
        result = client.workspace_symbols(args.query,
                                           args.page, args.page_size, args.page_max_bytes)

    elif args.command == 'formatting':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.formatting(args.file,
                                        page=args.page, page_size=args.page_size,
                                        page_max_bytes=args.page_max_bytes)

    elif args.command == 'rename':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.rename(args.file, args.line, args.character, args.new_name)
            # rename 返回 WorkspaceEdit，结构复杂，不分页

    elif args.command == 'signature':
        open_result = client.open_file(args.file)
        if not open_result.get('ok'):
            result = open_result
        else:
            result = client.signature_help(args.file, args.line, args.character)

    # 输出结果
    print(json.dumps(result, indent=2, ensure_ascii=False))

    # 返回状态码
    sys.exit(0 if result and result.get('ok') else 1)


if __name__ == '__main__':
    main()
