'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

return view.extend({
	runCommand: function(command) {
		return fs.exec('/usr/bin/tarm', [ command ]).then(function(result) {
			if (result.code !== 0) {
				var message = (result.stderr || result.stdout || _('TARM command failed.')).trim();
				ui.addNotification(null, E('p', {}, message), 'danger');
				throw new Error(message);
			}
			return result;
		});
	},

	disclosureState: function() {
		var node = document.querySelector('#view .cbi-map');
		return {
			connection: !!(node && node.querySelector('.tarm-connection-details[open]'))
		};
	},

	handleSave: function(ev) {
		var self = this;
		var state = this.disclosureState();
		return view.prototype.handleSave.call(this, ev).then(function(result) {
			self.decorateMap(document.querySelector('#view .cbi-map'), state);
			return result;
		});
	},

	handleReset: function(ev) {
		var self = this;
		var state = this.disclosureState();
		return view.prototype.handleReset.call(this, ev).then(function(result) {
			self.decorateMap(document.querySelector('#view .cbi-map'), state);
			return result;
		});
	},

	handleSaveApply: function(ev, mode) {
		var self = this;
		return this.handleSave(ev)
			.then(function() { return ui.changes.apply(mode == '0'); })
			.then(function() { return self.runCommand('apply'); });
	},

	render: function() {
		var self = this;
		if (!document.getElementById('tarm-preset-style'))
			document.head.appendChild(E('link', {
				'id': 'tarm-preset-style',
				'rel': 'stylesheet',
				'href': '/luci-static/resources/tarm/presets.css?v=0.6.0-r9'
			}));
		var m = new form.Map('tarm', _('TARM'),
			_('Tiny Amnezia Routing Manager for small OpenWrt routers.'));
		var s = m.section(form.NamedSection, 'main', 'main', _('Connection'));
		s.addremove = false;

		var o = s.option(form.Flag, 'enabled', _('Enable routing'));
		o.default = '0';

		o = s.option(form.Value, 'interface', _('Tunnel interface'));
		o.default = 'awg0';
		o.rmempty = false;

		o = s.option(form.Value, 'lan_device', _('LAN device'));
		o.default = 'br-lan';
		o.rmempty = false;

		o = s.option(form.Value, 'wan_interface', _('WAN interface'));
		o.default = 'wan';
		o.rmempty = false;
		o.description = _('OpenWrt interface name used to reconnect the tunnel after WAN comes up.');

		o = s.option(form.Value, 'dns_server', _('VPN DNS server'));
		o.datatype = 'ipaddr';
		o.placeholder = '10.0.0.1';
		o.description = _('Optional. Selected domains are resolved through this server inside the tunnel.');

		o = s.option(form.TextValue, '_tunnel', _('AmneziaWG configuration'));
		o.rows = 14;
		o.monospace = true;
		o.cfgvalue = function() {
			return L.resolveDefault(fs.read('/etc/tarm/tunnel.conf'), '').then(function(value) {
				self.tunnelOriginal = value.trim().replace(/\r\n/g, '\n');
				return value;
			});
		};
		o.write = function(section_id, value) {
			var content = value.trim().replace(/\r\n/g, '\n');
			if (content === self.tunnelOriginal)
				return Promise.resolve();
			return fs.write('/etc/tarm/tunnel.upload', content ? content + '\n' : '')
				.then(function() {
					return fs.exec('/usr/bin/tarm', [ 'import', '/etc/tarm/tunnel.upload' ]);
				})
				.then(function(result) {
					if (result.code !== 0)
						throw new Error((result.stderr || _('Invalid AmneziaWG configuration.')).trim());
					self.tunnelOriginal = content;
				});
		};

		var presets = [
			[ 'telegram', 'Telegram', 31 ],
			[ 'meta', 'Meta (WA+FB+Instagram)', 657 ],
			[ 'youtube', 'YouTube', 179 ],
			[ 'discord', 'Discord', 32 ],
			[ 'x_twitter', 'X (Twitter)', 40 ],
			[ 'tiktok', 'TikTok', 36 ],
			[ 'roblox', 'Roblox', 50 ],
			[ 'supercell', 'Supercell', 24 ],
			[ 'geoblock', 'GeoBlock', 1022 ],
			[ 'akamai', 'Akamai', 654 ],
			[ 'aws', 'AWS', 567 ],
			[ 'azure', 'Azure', 776 ],
			[ 'cloudflare', 'Cloudflare', 25 ],
			[ 'digitalocean', 'DigitalOcean', 174 ],
			[ 'google_cloud', 'Google Cloud', 162 ],
			[ 'hetzner', 'Hetzner', 82 ],
			[ 'oracle', 'Oracle', 127 ],
			[ 'ovh', 'OVH', 612 ]
		];
		var presetSection = m.section(form.NamedSection, 'main', 'main', _('Built-in VPN lists'));
		presetSection.addremove = false;
		presets.forEach(function(preset) {
			var flag = presetSection.option(form.Flag, 'preset_' + preset[0], '%s (%s)'.format(preset[1], preset[2]));
			flag.default = '0';
		});

		var lists = m.section(form.GridSection, 'list', _('Routing lists'));
		lists.addremove = true;
		lists.anonymous = false;
		lists.nodescriptions = true;
		lists.description = _('Create a list with domains, IP addresses or CIDR subnets, then route the whole list through VPN or directly. Entry type is detected automatically.');

		o = lists.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;

		o = lists.option(form.ListValue, 'route', _('Route'));
		o.value('vpn', _('VPN'));
		o.value('direct', _('Direct'));
		o.default = 'vpn';

		o = lists.option(form.DummyValue, '_source', _('Source'));
		o.cfgvalue = function(section_id) {
			var catalog = uci.get('tarm', section_id, 'catalog');
			if (catalog) return _('Catalog: %s').format(catalog);
			return uci.get('tarm', section_id, 'url') ? _('HTTPS subscription') : _('Manual');
		};

		o = lists.option(form.DynamicList, 'domain', _('Domains, IPs and subnets'));
		o.placeholder = 'example.org or 203.0.113.0/24';
		o.modalonly = true;
		o.description = _('One entry per line. Domain subdomains are included; IPv4, IPv6 and CIDR are supported.');

		o = lists.option(form.Value, 'catalog', _('Catalog source'));
		o.placeholder = 'telegram';
		o.modalonly = true;
		o.description = _('Optional v2fly catalog name. The catalog importer fills this field automatically.');
		o.validate = function(section_id, value) {
			return !value || (/^[a-z0-9][a-z0-9_-]*$/.test(value) && value.length <= 64) || _('Invalid catalog name.');
		};

		o = lists.option(form.Value, 'url', _('Optional HTTPS subscription'));
		o.placeholder = 'https://example.org/domains.txt';
		o.modalonly = true;
		o.description = _('Downloaded entries are combined with entries above. Catalog source takes priority when both are set.');
		o.validate = function(section_id, value) {
			return !value || /^https:\/\/[^\s]+$/i.test(value) || _('Use an HTTPS URL.');
		};

		o = s.option(form.Button, '_apply', _('Apply saved settings now'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return self.runCommand('apply');
		};

		o = s.option(form.Button, '_update', _('Update lists'));
		o.inputstyle = 'action';
		o.onclick = function() {
			return self.runCommand('update');
		};

		self.decorateMap = function(node, state) {
			if (!node) return node;
			if (node.querySelector('.tarm-connection-details') && node.querySelector('.tarm-import-toolbar')) return node;
			var connection = node.querySelector('.cbi-value[data-name="interface"]');
			if (connection && !node.querySelector('.tarm-connection-details')) {
				connection = connection.closest('.cbi-section');
				var connectionDetails = E('details', { 'class': 'tarm-disclosure tarm-connection-details' }, [
					E('summary', _('Connection and maintenance'))
				]);
				connectionDetails.open = !!(state && state.connection);
				connection.parentNode.insertBefore(connectionDetails, connection);
				connectionDetails.appendChild(connection);
			}

			var panel = E('div', { 'class': 'tarm-import-panel' });
			var catalogPane = E('div', { 'class': 'tarm-import-pane' }, [
				E('p', _('Find a list in the community catalog and add it to VPN routing.'))
			]);
			var customPane = E('div', { 'class': 'tarm-import-pane' }, [
				E('p', _('Paste domains, IP addresses or CIDR subnets, or choose a text file.'))
			]);

			var catalogInput = E('input', {
				'class': 'cbi-input-text',
				'list': 'tarm-catalog-names',
				'placeholder': 'telegram'
			});
			var catalogData = E('datalist', { 'id': 'tarm-catalog-names' });
			var catalogButton = E('button', {
				'class': 'cbi-button cbi-button-add',
				'disabled': ''
			}, _('Add VPN list'));
			var catalogStatus = E('div', { 'class': 'cbi-value-description' },
				_('Loading catalog…'));
			catalogPane.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Community catalog')),
				E('div', { 'class': 'cbi-value-field' }, [
					catalogInput, catalogData, ' ', catalogButton, catalogStatus
				])
			]));

			var catalogNames = [];
			fetch('/luci-static/resources/tarm/catalog.txt')
				.then(function(response) {
					if (!response.ok) throw new Error(_('Could not load catalog index.'));
					return response.text();
				})
				.then(function(data) {
					catalogNames = data.split(/\r?\n/).filter(function(name) {
						return /^[a-z0-9][a-z0-9_-]*$/.test(name);
					});
					catalogNames.forEach(function(name) {
						catalogData.appendChild(E('option', { 'value': name }));
					});
					catalogButton.disabled = false;
					catalogStatus.textContent = _('%s lists available. Start typing to search.').format(catalogNames.length);
				})
				.catch(function(error) { catalogStatus.textContent = error.message; });

			catalogButton.addEventListener('click', function(ev) {
				ev.preventDefault();
				var name = catalogInput.value.trim().toLowerCase();
				if (catalogNames.indexOf(name) < 0) {
					catalogStatus.textContent = _('Choose a name from the catalog.');
					return;
				}
				catalogButton.disabled = true;
				catalogStatus.textContent = _('Downloading list…');
				fs.exec('/usr/bin/tarm', [ 'catalog-add', name ])
					.then(function(result) {
						if (result.code !== 0) throw new Error(result.stderr || _('Catalog import failed.'));
						window.location.reload();
					})
					.catch(function(error) {
						catalogStatus.textContent = error.message;
						catalogButton.disabled = false;
					});
			});

			var listSelect = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': '' }, _('Choose a saved list…'))
			]);
			uci.sections('tarm', 'list').forEach(function(section) {
				listSelect.appendChild(E('option', { 'value': section['.name'] }, section['.name']));
			});
			var listText = E('textarea', {
				'class': 'cbi-input-textarea',
				'rows': 6,
				'placeholder': 'example.org\n203.0.113.7\n2001:db8::/32',
				'style': 'width: 100%; max-width: 700px;'
			});
			var listFile = E('input', { 'type': 'file', 'accept': '.txt,text/plain' });
			var listMode = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'append' }, _('Add to existing entries')),
				E('option', { 'value': 'replace' }, _('Replace imported entries'))
			]);
			var listButton = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Import entries'));
			var listStatus = E('div', { 'class': 'cbi-value-description' },
				_('Create and save a list above before importing. Maximum 256 KiB per upload.'));
			customPane.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Your list')),
				E('div', { 'class': 'cbi-value-field' }, [
					listSelect, ' ', listMode, E('div', [ listText ]),
					listFile, ' ', listButton, listStatus
				])
			]));

			listFile.addEventListener('change', function() {
				var file = listFile.files[0];
				if (!file) return;
				if (file.size > 262144) {
					listStatus.textContent = _('File exceeds 256 KiB.');
					return;
				}
				var reader = new FileReader();
				reader.onload = function() {
					listText.value = reader.result;
					listStatus.textContent = _('File loaded. Click Import entries.');
				};
				reader.onerror = function() { listStatus.textContent = _('Could not read file.'); };
				reader.readAsText(file);
			});

			listButton.addEventListener('click', function(ev) {
				ev.preventDefault();
				var name = listSelect.value;
				var contents = listText.value;
				if (!name || !contents.trim()) {
					listStatus.textContent = _('Choose a saved list and paste entries or select a file.');
					return;
				}
				if (new TextEncoder().encode(contents).length > 262144) {
					listStatus.textContent = _('Text exceeds 256 KiB.');
					return;
				}
				listButton.disabled = true;
				listStatus.textContent = _('Importing entries…');
				fs.write('/etc/tarm/import.txt', contents)
					.then(function() { return fs.exec('/usr/bin/tarm', [ 'import-list', name, listMode.value ]); })
					.then(function(result) {
						if (result.code !== 0) throw new Error(result.stderr || _('Import failed.'));
						listStatus.textContent = (result.stdout || _('Entries imported.')).trim();
						listText.value = '';
						listFile.value = '';
					})
					.catch(function(error) { listStatus.textContent = error.message; })
					.finally(function() { listButton.disabled = false; });
			});

			var catalogTab = E('button', { 'class': 'tarm-import-tab active', 'type': 'button' }, _('Community catalog'));
			var customTab = E('button', { 'class': 'tarm-import-tab', 'type': 'button' }, _('Your domains and IPs'));
			var showTab = function(which) {
				catalogPane.hidden = which != 'catalog';
				customPane.hidden = which != 'custom';
				catalogTab.classList.toggle('active', which == 'catalog');
				customTab.classList.toggle('active', which == 'custom');
			};
			catalogTab.addEventListener('click', function() { showTab('catalog'); });
			customTab.addEventListener('click', function() { showTab('custom'); });
			panel.appendChild(E('div', { 'class': 'tarm-import-tabs' }, [ catalogTab, customTab ]));
			panel.appendChild(catalogPane);
			panel.appendChild(customPane);
			showTab('catalog');

			var importButton = E('button', { 'class': 'cbi-button cbi-button-add', 'type': 'button' }, _('Import a list'));
			importButton.addEventListener('click', function() {
				ui.showModal(_('Add a list'), [
					panel,
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'type': 'button', 'click': ui.hideModal }, _('Close'))
					])
				]);
			});
			var importToolbar = E('div', { 'class': 'tarm-import-toolbar' }, [ importButton ]);
			var actions = node.querySelector('.cbi-page-actions');
			if (!node.querySelector('.tarm-import-toolbar')) {
				if (actions) actions.parentNode.insertBefore(importToolbar, actions);
				else node.appendChild(importToolbar);
			}
			return node;
		};
		return m.render().then(function(node) { return self.decorateMap(node); });
	}
});
