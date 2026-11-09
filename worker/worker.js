import { connect } from 'cloudflare:sockets';

const WS_READY_STATE_OPEN = 1;
const WS_READY_STATE_CLOSING = 2;

export default {
    async fetch(request, env, ctx) {
        try {
            const settings = readSettings(env);
            if (!settings) return new Response('Not found', { status: 404 });

            const upgrade = request.headers.get('Upgrade');
            if (upgrade && upgrade.toLowerCase() === 'websocket') {
                return vOverWS(request, settings);
            }
            return fallback(request, settings);
        } catch {
            return new Response('Internal error', { status: 500 });
        }
    },
};

function readSettings(env) {
    try {
        const data = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(env.ENV), (c) => c.charCodeAt(0))));
        if (!data || data.v !== 1 || typeof data.id !== 'string' || !data.id) return null;
        const pips = (Array.isArray(data.pips) ? data.pips : [])
            .map((s) => String(s).trim())
            .filter(Boolean);

        return {
            id: data.id.toLowerCase(),
            pips,
            fb: String(data.fb || '').trim(),
        };
    } catch {
        return null;
    }
}

async function fallback(request, settings) {
    if (settings.fb) {
        try {
            const target = new URL(settings.fb);
            const url = new URL(request.url);
            url.protocol = target.protocol;
            url.hostname = target.hostname;
            url.port = target.port;
            return fetch(new Request(url, request));
        } catch {
            // Fall through to the default page.
        }
    }
    return new Response('Not found', { status: 404, headers: { 'Content-Type': 'text/plain' } });
}

async function vOverWS(request, settings) {
    const webSocketPair = new WebSocketPair();
    const [client, webSocket] = Object.values(webSocketPair);
    webSocket.accept();
    webSocket.binaryType = 'arraybuffer';

    const earlyDataHeader = request.headers.get('sec-websocket-protocol') || '';
    const readableWebSocketStream = makeReadableWebSocketStream(webSocket, earlyDataHeader);

    const remoteSocket = { value: null };

    readableWebSocketStream
        .pipeTo(new WritableStream({
            async write(chunk) {
                if (remoteSocket.value) {
                    const writer = remoteSocket.value.writable.getWriter();
                    await writer.write(chunk);
                    writer.releaseLock();
                    return;
                }

                const header = parseVHeader(chunk, settings.id);
                if (header.hasError) throw new Error(header.message);

                const responseHeader = new Uint8Array([header.version[0], 0]);
                const rawClientData = chunk.slice(header.rawDataIndex);

                handleTCPOutBound(remoteSocket, header.addressRemote, header.portRemote, rawClientData, webSocket, responseHeader, settings);
            },
            close() {
                safeCloseTcpSocket(remoteSocket.value);
            },
        }))
        .catch(() => safeCloseTcpSocket(remoteSocket.value));

    // Browsers drop a WebSocket whose subprotocol (Xray's early data) isn't echoed back.
    const headers = earlyDataHeader ? { 'Sec-WebSocket-Protocol': earlyDataHeader } : undefined;
    return new Response(null, { status: 101, webSocket: client, headers });
}

function parseVHeader(buffer, userId) {
    if (buffer.byteLength < 24) return { hasError: true, message: 'invalid data' };

    const bytes = new Uint8Array(buffer);
    const version = bytes.slice(0, 1);
    if (uuidFromBytes(bytes, 1) !== userId) return { hasError: true, message: 'invalid user' };

    const optLength = bytes[17];
    const command = bytes[18 + optLength];
    // TCP only: the client blocks UDP and resolves DNS over DoH through TCP.
    if (command !== 1) {
        return { hasError: true, message: `command ${command} is not supported` };
    }

    const portIndex = 18 + optLength + 1;
    const portRemote = new DataView(buffer.slice(portIndex, portIndex + 2)).getUint16(0);

    const addressType = bytes[portIndex + 2];
    let addressValueIndex = portIndex + 3;
    let addressLength = 0;
    let addressRemote = '';

    switch (addressType) {
        case 1:
            addressLength = 4;
            addressRemote = bytes.slice(addressValueIndex, addressValueIndex + 4).join('.');
            break;
        case 2:
            addressLength = bytes[addressValueIndex];
            addressValueIndex += 1;
            addressRemote = new TextDecoder().decode(buffer.slice(addressValueIndex, addressValueIndex + addressLength));
            break;
        case 3: {
            addressLength = 16;
            const view = new DataView(buffer.slice(addressValueIndex, addressValueIndex + 16));
            const parts = [];
            for (let i = 0; i < 8; i++) parts.push(view.getUint16(i * 2).toString(16));
            addressRemote = parts.join(':');
            break;
        }
        default:
            return { hasError: true, message: `invalid address type ${addressType}` };
    }

    if (!addressRemote) return { hasError: true, message: 'empty address' };

    return {
        hasError: false,
        addressRemote,
        portRemote,
        rawDataIndex: addressValueIndex + addressLength,
        version,
    };
}

const byteToHex = Array.from({ length: 256 }, (_, i) => (i + 256).toString(16).slice(1));

function uuidFromBytes(arr, offset) {
    const h = (i) => byteToHex[arr[offset + i]];
    return (
        h(0) + h(1) + h(2) + h(3) + '-' + h(4) + h(5) + '-' + h(6) + h(7) + '-' +
        h(8) + h(9) + '-' + h(10) + h(11) + h(12) + h(13) + h(14) + h(15)
    );
}

async function handleTCPOutBound(remoteSocket, addressRemote, portRemote, rawClientData, webSocket, responseHeader, settings) {
    async function connectAndWrite(address, port) {
        if (address.includes(':') && !address.startsWith('[')) address = `[${address}]`;
        const tcpSocket = connect({ hostname: address, port });
        remoteSocket.value = tcpSocket;
        const writer = tcpSocket.writable.getWriter();
        await writer.write(rawClientData);
        writer.releaseLock();
        return tcpSocket;
    }

    // Cloudflare-hosted targets refuse direct connections from Workers; retry via a proxy IP.
    async function retry() {
        const randomItem = (arr) => arr[Math.floor(Math.random() * arr.length)];
        try {
            const endpoint = settings.pips.length
                ? randomItem(settings.pips)
                : atob('YnBiLnlvdXNlZi5pc2VnYXJvLmNvbQ==');
            const { host, port } = parseHostPort(endpoint);

            const tcpSocket = await connectAndWrite(host, port);
            tcpSocket.closed.catch(() => { }).finally(() => safeCloseWebSocket(webSocket));
            remoteSocketToWS(tcpSocket, webSocket, responseHeader, null);
        } catch (error) {
            webSocket.close(1011, `Retry failed: ${error && error.message || error}`);
        }
    }

    try {
        const tcpSocket = await connectAndWrite(addressRemote, portRemote);
        remoteSocketToWS(tcpSocket, webSocket, responseHeader, retry);
    } catch (error) {
        webSocket.close(1011, `Connection failed: ${error && error.message || error}`);
    }
}

async function remoteSocketToWS(remoteSocket, webSocket, responseHeader, retry) {
    let header = responseHeader;
    let hasIncomingData = false;

    try {
        await remoteSocket.readable.pipeTo(new WritableStream({
            async write(chunk, controller) {
                hasIncomingData = true;
                if (webSocket.readyState !== WS_READY_STATE_OPEN) {
                    controller.error('WebSocket is not open');
                }
                if (header) {
                    webSocket.send(await new Blob([header, chunk]).arrayBuffer());
                    header = null;
                } else {
                    webSocket.send(chunk);
                }
            },
            abort() {
                safeCloseTcpSocket(remoteSocket);
            },
        }));
    } catch {
        safeCloseTcpSocket(remoteSocket);
        safeCloseWebSocket(webSocket);
    }

    if (!hasIncomingData && retry) retry();
}

function makeReadableWebSocketStream(webSocket, earlyDataHeader) {
    let cancelled = false;
    return new ReadableStream({
        start(controller) {
            webSocket.addEventListener('message', (event) => {
                if (!cancelled) controller.enqueue(event.data);
            });
            webSocket.addEventListener('close', () => {
                safeCloseWebSocket(webSocket);
                if (!cancelled) controller.close();
            });
            webSocket.addEventListener('error', (err) => controller.error(err));

            const { earlyData, error } = base64ToArrayBuffer(earlyDataHeader);
            if (error) controller.error(error);
            else if (earlyData) controller.enqueue(earlyData);
        },
        cancel() {
            if (cancelled) return;
            cancelled = true;
            safeCloseWebSocket(webSocket);
        },
    });
}

function base64ToArrayBuffer(base64Str) {
    if (!base64Str) return { earlyData: null, error: null };
    try {
        const decoded = atob(base64Str.replace(/-/g, '+').replace(/_/g, '/'));
        return { earlyData: Uint8Array.from(decoded, (c) => c.charCodeAt(0)).buffer, error: null };
    } catch (error) {
        return { earlyData: null, error };
    }
}

function safeCloseTcpSocket(socket) {
    try {
        if (socket) socket.close();
    } catch { }
}

function safeCloseWebSocket(socket) {
    try {
        if (socket.readyState === WS_READY_STATE_OPEN || socket.readyState === WS_READY_STATE_CLOSING) socket.close();
    } catch { }
}

function parseHostPort(input) {
    const match = String(input).trim().match(/^(?:\[(?<ipv6>.+?)\]|(?<host>[^:]+))(?::(?<port>\d+))?$/);
    if (!match) throw new Error(`Invalid host:port: ${input}`);
    const { ipv6, host, port } = match.groups;
    return {
        host: ipv6 ? `[${ipv6}]` : host,
        port: port ? Number(port) : 443
    };
}