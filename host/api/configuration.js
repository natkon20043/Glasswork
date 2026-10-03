'use strict';

// vscode.workspace.getConfiguration: settings read synchronously. Glasswork pushes its
// settings.json to the host; each extension's own defaults come from the
// `contributes.configuration` section of its package.json.

const { EventEmitter, ConfigurationTarget } = require('./types');

function flatten(object, prefix, into) {
    for (const [key, value] of Object.entries(object || {})) {
        const name = prefix ? `${prefix}.${key}` : key;
        const isPlainObject = value !== null && typeof value === 'object' && !Array.isArray(value);
        into[name] = value;
        if (isPlainObject) {
            flatten(value, name, into);
        }
    }
    return into;
}

class ConfigurationStore {
    constructor(updateHandler) {
        this.defaults = {};
        this.user = {};
        this.updateHandler = updateHandler;
        this.emitter = new EventEmitter();
    }

    // Registers the defaults an extension declares in contributes.configuration.
    addDefaults(manifestConfiguration) {
        const sections = Array.isArray(manifestConfiguration) ? manifestConfiguration : [manifestConfiguration];
        for (const section of sections) {
            if (!section || typeof section !== 'object' || !section.properties) {
                continue;
            }
            for (const [key, schema] of Object.entries(section.properties)) {
                if (schema && schema.default !== undefined) {
                    this.defaults[key] = schema.default;
                } else if (schema && schema.type === 'boolean') {
                    this.defaults[key] = false;
                }
            }
        }
    }

    // Replaces the user's settings (a nested or dotted JSON object) and reports what changed.
    setUserSettings(settings) {
        const before = this.user;
        const flat = {};
        flatten(settings, '', flat);
        this.user = flat;
        const changedKeys = new Set();
        for (const key of new Set([...Object.keys(before), ...Object.keys(flat)])) {
            if (JSON.stringify(before[key]) !== JSON.stringify(flat[key])) {
                changedKeys.add(key);
            }
        }
        if (changedKeys.size > 0) {
            this.emitter.fire({
                affectsConfiguration: (section) => {
                    for (const key of changedKeys) {
                        if (key === section || key.startsWith(section + '.') || section.startsWith(key + '.')) {
                            return true;
                        }
                    }
                    return false;
                },
            });
        }
    }

    get onDidChange() {
        return this.emitter.event;
    }

    // The value at a dotted path: a user setting, else a default; for a section, the object
    // assembled from every key under it.
    value(path) {
        if (Object.prototype.hasOwnProperty.call(this.user, path)) {
            return this.user[path];
        }
        const assembled = this.assemble(path);
        if (assembled !== undefined) {
            return assembled;
        }
        return this.defaults[path];
    }

    userValue(path) {
        return Object.prototype.hasOwnProperty.call(this.user, path) ? this.user[path] : undefined;
    }

    defaultValue(path) {
        return this.defaults[path];
    }

    assemble(path) {
        const prefix = path + '.';
        let result;
        const names = new Set([...Object.keys(this.defaults), ...Object.keys(this.user)]);
        for (const name of names) {
            if (!name.startsWith(prefix)) {
                continue;
            }
            const rest = name.slice(prefix.length);
            if (rest.includes('.') && names.has(name.slice(0, name.lastIndexOf('.')))) {
                continue; // already inside an object value
            }
            result = result || {};
            result[rest] = Object.prototype.hasOwnProperty.call(this.user, name) ? this.user[name] : this.defaults[name];
        }
        return result;
    }

    getConfiguration(section) {
        const store = this;
        const qualify = (key) => (section ? `${section}.${key}` : key);
        const configuration = {
            get(key, defaultValue) {
                const value = store.value(qualify(key));
                return value === undefined ? defaultValue : value;
            },
            has(key) {
                return store.value(qualify(key)) !== undefined;
            },
            inspect(key) {
                const name = qualify(key);
                return {
                    key: name,
                    defaultValue: store.defaultValue(name),
                    globalValue: store.userValue(name),
                    workspaceValue: undefined,
                    workspaceFolderValue: undefined,
                };
            },
            async update(key, value, target) {
                const name = qualify(key);
                if (value === undefined) {
                    delete store.user[name];
                } else {
                    store.user[name] = value;
                }
                if (store.updateHandler) {
                    await store.updateHandler(name, value, target || ConfigurationTarget.Global);
                }
            },
        };
        // Extensions also read settings as plain properties (config.someSetting).
        const assembled = section ? store.assemble(section) : undefined;
        if (assembled) {
            for (const [key, value] of Object.entries(assembled)) {
                if (!(key in configuration)) {
                    configuration[key] = value;
                }
            }
        }
        return configuration;
    }
}

module.exports = { ConfigurationStore };
