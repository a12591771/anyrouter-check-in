import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from checkin import login_with_api
from utils.config import AppConfig


def _provider(monkeypatch):
	monkeypatch.delenv('PROVIDERS', raising=False)
	return AppConfig.load_from_env().providers['agentrouter']


def _mock_client(response):
	client = MagicMock()
	client.post.return_value = response
	client.cookies = {'session': 'session-value'}
	context = MagicMock()
	context.__enter__.return_value = client
	context.__exit__.return_value = False
	return context, client


def test_builtin_agentrouter_supports_api_login(monkeypatch):
	provider = _provider(monkeypatch)

	assert provider.supports_api_login() is True
	assert provider.login_api_path == '/api/user/login'


def test_builtin_anyrouter_keeps_browser_login(monkeypatch):
	monkeypatch.delenv('PROVIDERS', raising=False)

	assert AppConfig.load_from_env().providers['anyrouter'].supports_api_login() is False


def test_api_login_returns_cookies_and_api_user(monkeypatch):
	provider = _provider(monkeypatch)
	monkeypatch.delenv('CHECKIN_PROXY_URL', raising=False)
	response = MagicMock(status_code=200)
	response.json.return_value = {'success': True, 'data': {'id': 481696, 'username': 'github_481696'}}
	context, client = _mock_client(response)

	with patch('httpx.Client', return_value=context):
		result = login_with_api('acct', provider, 'user@example.com', 'secret')

	assert result is not None
	assert result.cookies == {'session': 'session-value'}
	assert result.api_user == '481696'
	assert client.post.call_args.kwargs['json'] == {'username': 'user@example.com', 'password': 'secret'}


def test_api_login_returns_none_when_server_rejects(monkeypatch):
	provider = _provider(monkeypatch)
	monkeypatch.delenv('CHECKIN_PROXY_URL', raising=False)
	response = MagicMock(status_code=200)
	response.json.return_value = {'success': False, 'message': '用户名或密码错误'}
	context, _ = _mock_client(response)

	with patch('httpx.Client', return_value=context):
		assert login_with_api('acct', provider, 'user@example.com', 'wrong') is None


def test_api_login_returns_none_on_waf_html(monkeypatch):
	provider = _provider(monkeypatch)
	monkeypatch.delenv('CHECKIN_PROXY_URL', raising=False)
	response = MagicMock(status_code=200)
	response.json.side_effect = json.JSONDecodeError('Expecting value', '', 0)
	context, _ = _mock_client(response)

	with patch('httpx.Client', return_value=context):
		assert login_with_api('acct', provider, 'user@example.com', 'secret') is None
