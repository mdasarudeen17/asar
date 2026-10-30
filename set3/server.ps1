param (
    [int]$port = 3000
)

$rootDir = $PSScriptRoot
if (-not $rootDir) { $rootDir = (Get-Location).Path }

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Collections.Generic;

public class FastHttpServer
{
    private TcpListener _listener;
    private string _root;
    private volatile bool _running;

    public void Start(string rootDir, int port)
    {
        _root = Path.GetFullPath(rootDir);
        _listener = new TcpListener(IPAddress.Loopback, port);
        _listener.Start(200);
        _running = true;

        Thread t = new Thread(ListenLoop);
        t.IsBackground = true;
        t.Start();
    }

    private void ListenLoop()
    {
        while (_running)
        {
            try
            {
                TcpClient client = _listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(state => ProcessClient((TcpClient)state), client);
            }
            catch
            {
                if (!_running) break;
            }
        }
    }

    private void ProcessClient(TcpClient client)
    {
        using (client)
        {
            try
            {
                client.ReceiveTimeout = 5000;
                client.SendTimeout = 5000;
                NetworkStream stream = client.GetStream();

                byte[] buffer = new byte[4096];
                int bytesRead = stream.Read(buffer, 0, buffer.Length);
                if (bytesRead <= 0) return;

                string requestStr = Encoding.UTF8.GetString(buffer, 0, bytesRead);
                string firstLine = requestStr.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)[0];
                string[] parts = firstLine.Split(' ');
                if (parts.Length < 2) return;

                string method = parts[0];
                string rawUrl = parts[1];

                int queryIdx = rawUrl.IndexOf('?');
                string path = queryIdx >= 0 ? rawUrl.Substring(0, queryIdx) : rawUrl;
                path = Uri.UnescapeDataString(path.TrimStart('/'));
                if (string.IsNullOrEmpty(path)) path = "index.html";

                string fullPath = Path.Combine(_root, path.Replace('/', Path.DirectorySeparatorChar));

                if (File.Exists(fullPath))
                {
                    string ext = Path.GetExtension(fullPath).ToLowerInvariant();
                    string contentType = "application/octet-stream";
                    if (ext == ".html") contentType = "text/html; charset=utf-8";
                    else if (ext == ".js") contentType = "application/javascript; charset=utf-8";
                    else if (ext == ".css") contentType = "text/css; charset=utf-8";
                    else if (ext == ".jpg" || ext == ".jpeg") contentType = "image/jpeg";
                    else if (ext == ".png") contentType = "image/png";
                    else if (ext == ".mp4") contentType = "video/mp4";

                    byte[] content = File.ReadAllBytes(fullPath);

                    StringBuilder sb = new StringBuilder();
                    sb.Append("HTTP/1.1 200 OK\r\n");
                    sb.Append("Content-Type: ").Append(contentType).Append("\r\n");
                    sb.Append("Content-Length: ").Append(content.Length).Append("\r\n");
                    sb.Append("Access-Control-Allow-Origin: *\r\n");

                    if (ext == ".html")
                    {
                        sb.Append("Cache-Control: no-cache, no-store, must-revalidate\r\n");
                    }
                    else
                    {
                        sb.Append("Cache-Control: public, max-age=86400\r\n");
                    }

                    sb.Append("Connection: close\r\n\r\n");

                    byte[] headerBytes = Encoding.UTF8.GetBytes(sb.ToString());
                    stream.Write(headerBytes, 0, headerBytes.Length);
                    stream.Write(content, 0, content.Length);
                    stream.Flush();
                }
                else
                {
                    byte[] notFound = Encoding.UTF8.GetBytes("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found");
                    stream.Write(notFound, 0, notFound.Length);
                    stream.Flush();
                }
            }
            catch {}
        }
    }

    public void Stop()
    {
        _running = false;
        try { _listener.Stop(); } catch {}
    }
}
"@

$server = New-Object FastHttpServer
$server.Start($rootDir, $port)

Write-Host "Folioblox web server is running at http://localhost:$port/"

try {
    while ($true) {
        Start-Sleep -Seconds 1
    }
}
finally {
    $server.Stop()
}
