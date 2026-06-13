'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({
	object: 'zerotier.support',
	method: 'status',
	expect: { '': {} }
});

var callInstall = rpc.declare({
	object: 'zerotier.support',
	method: 'install',
	expect: { '': {} }
});

var callConfigure = rpc.declare({
	object: 'zerotier.support',
	method: 'configure',
	params: [ 'network_id' ],
	expect: { '': {} }
});

var callLeave = rpc.declare({
	object: 'zerotier.support',
	method: 'leave',
	params: [ 'network_id' ],
	expect: { '': {} }
});

var callRestart = rpc.declare({
	object: 'zerotier.support',
	method: 'restart',
	expect: { '': {} }
});

var callDisable = rpc.declare({
	object: 'zerotier.support',
	method: 'disable',
	expect: { '': {} }
});

var callDiagnose = rpc.declare({
	object: 'zerotier.support',
	method: 'diagnose',
	params: [ 'target' ],
	expect: { '': {} }
});

function notify(result, okText) {
	var success = result && result.success !== false;
	var message = success ? okText : _('Команда не выполнена');

	ui.addNotification(null, E('p', message), success ? 'info' : 'danger');
}

function outputText(result) {
	return String((result && result.output) || '').trim() || _('Нет данных');
}

function parseCurrentNetworkId(output) {
	var match = String(output || '').match(/Network ID:\s*([0-9a-fA-F]{16})/);
	if (match) return match[1];

	match = String(output || '').match(/zerotier\.router_support\.id='([0-9a-fA-F]{16})'/);
	return match ? match[1] : '';
}

function setBusy(buttons, busy) {
	buttons.forEach(function(button) {
		if (button) button.disabled = busy;
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	render: function(data) {
		var networkInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': '0123456789abcdef',
			'value': parseCurrentNetworkId(outputText(data)),
			'maxlength': '16',
			'autocapitalize': 'none',
			'autocomplete': 'off',
			'spellcheck': 'false',
			'style': 'min-width: 260px;'
		});

		var targetInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'placeholder': '10.0.0.1',
			'autocapitalize': 'none',
			'autocomplete': 'off',
			'spellcheck': 'false',
			'style': 'min-width: 220px;'
		});

		var output = E('pre', {
			'style': [
				'white-space: pre-wrap',
				'overflow: auto',
				'max-height: 560px',
				'padding: 12px',
				'border-radius: 6px',
				'background: var(--background-color-high, #101418)',
				'color: var(--text-color-high, inherit)'
			].join(';')
		}, outputText(data));

		var refreshButton = E('button', {
			'class': 'cbi-button',
			'type': 'button'
		}, _('Обновить'));

		var installButton = E('button', {
			'class': 'cbi-button',
			'type': 'button'
		}, _('Установить / починить'));

		var joinButton = E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button'
		}, _('Подключить / сохранить'));

		var restartButton = E('button', {
			'class': 'cbi-button',
			'type': 'button'
		}, _('Перезапустить ZeroTier'));

		var leaveButton = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'type': 'button'
		}, _('Отключить от сети'));

		var disableButton = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'type': 'button'
		}, _('Выключить ZeroTier'));

		var diagnoseButton = E('button', {
			'class': 'cbi-button',
			'type': 'button'
		}, _('Проверить связь'));

		var buttons = [
			refreshButton,
			installButton,
			joinButton,
			restartButton,
			leaveButton,
			disableButton,
			diagnoseButton
		];

		function update(result, message) {
			output.textContent = outputText(result);
			if (message) notify(result, message);
		}

		function run(button, promise, message) {
			setBusy(buttons, true);
			button.classList.add('spinning');

			return promise.then(function(result) {
				update(result, message);
			}).catch(function(error) {
				output.textContent = String(error && error.message ? error.message : error);
				ui.addNotification(null, E('p', _('Команда не выполнена')), 'danger');
			}).finally(function() {
				button.classList.remove('spinning');
				setBusy(buttons, false);
			});
		}

		refreshButton.addEventListener('click', function() {
			run(refreshButton, callStatus(), _('Статус обновлен'));
		});

		installButton.addEventListener('click', function() {
			run(installButton, callInstall(), _('Панель и ZeroTier проверены'));
		});

		joinButton.addEventListener('click', function() {
			var networkId = String(networkInput.value || '').trim();

			if (!/^[0-9a-fA-F]{16}$/.test(networkId)) {
				ui.addNotification(null, E('p', _('Network ID должен состоять из 16 символов HEX.')), 'danger');
				return;
			}

			run(joinButton, callConfigure(networkId), _('Сеть ZeroTier настроена'));
		});

		restartButton.addEventListener('click', function() {
			run(restartButton, callRestart(), _('ZeroTier перезапущен'));
		});

		leaveButton.addEventListener('click', function() {
			var networkId = String(networkInput.value || '').trim();
			run(leaveButton, callLeave(networkId), _('Роутер отключен от сети ZeroTier'));
		});

		disableButton.addEventListener('click', function() {
			run(disableButton, callDisable(), _('ZeroTier выключен'));
		});

		diagnoseButton.addEventListener('click', function() {
			run(diagnoseButton, callDiagnose(String(targetInput.value || '').trim()), _('Диагностика выполнена'));
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', _('ZeroTier')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', _('ZeroTier используется только для удаленного доступа к роутеру. Маршруты по умолчанию, глобальные маршруты и DNS от ZeroTier остаются выключенными.')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Network ID')),
					E('div', { 'class': 'cbi-value-field' }, [
						networkInput,
						' ',
						joinButton
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Цель проверки')),
					E('div', { 'class': 'cbi-value-field' }, [
						targetInput,
						' ',
						diagnoseButton
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Действия')),
					E('div', { 'class': 'cbi-value-field' }, [
						refreshButton,
						' ',
						installButton,
						' ',
						restartButton,
						' ',
						leaveButton,
						' ',
						disableButton
					])
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Диагностика')),
				output
			])
		]);
	}
});
