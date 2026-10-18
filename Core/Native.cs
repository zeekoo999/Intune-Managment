// IntuneManager native helpers. Compiled at runtime with Add-Type.
// - JsonHelper: parses JSON into PSCustomObject trees WITHOUT converting
//   date-like strings to DateTime (ConvertFrom-Json in PS 7.4 does that and
//   silently changes values on re-export).
// - GraphException: typed Graph error carrying status, code and request ids.
using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Text.Json;

namespace IntuneManager
{
    public class GraphException : Exception
    {
        public int StatusCode { get; set; }
        public string ErrorCode { get; set; }
        public string GraphMessage { get; set; }
        public string RequestId { get; set; }
        public string ClientRequestId { get; set; }
        public string Method { get; set; }
        public string Url { get; set; }
        public string ResponseBody { get; set; }
        public int Attempts { get; set; }
        public bool IsTransient { get; set; }

        public GraphException(string message) : base(message) { }
        public GraphException(string message, Exception inner) : base(message, inner) { }

        public override string ToString()
        {
            return string.Format("{0} {1} -> {2} {3}: {4} (request-id: {5}, client-request-id: {6}, attempts: {7})",
                Method, Url, StatusCode, ErrorCode, GraphMessage ?? Message, RequestId, ClientRequestId, Attempts);
        }
    }

    // ---- UI row models (INotifyPropertyChanged so WPF grids update live) ----
    public abstract class NotifyBase : System.ComponentModel.INotifyPropertyChanged
    {
        public event System.ComponentModel.PropertyChangedEventHandler PropertyChanged;
        protected void Set<T>(ref T field, T value, string name)
        {
            if (Equals(field, value)) return;
            field = value;
            var h = PropertyChanged;
            if (h != null) h(this, new System.ComponentModel.PropertyChangedEventArgs(name));
        }
    }

    public class ObjectRow : NotifyBase
    {
        private bool _selected;
        public bool Selected { get { return _selected; } set { Set(ref _selected, value, "Selected"); } }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Kind { get; set; }
        public string Platform { get; set; }
        public string Modified { get; set; }
        public string Assigned { get; set; }
        public string Id { get; set; }
        public object Tag { get; set; }
    }

    public class PlanRow : NotifyBase
    {
        private bool _selected = true;
        private string _status = "";
        private string _message = "";
        public bool Selected { get { return _selected; } set { Set(ref _selected, value, "Selected"); } }
        public string Status { get { return _status; } set { Set(ref _status, value, "Status"); } }
        public string Message { get { return _message; } set { Set(ref _message, value, "Message"); } }
        public string TypeTitle { get; set; }
        public string Name { get; set; }
        public int Order { get; set; }
        public int Assignments { get; set; }
        public string Note { get; set; }
        public string File { get; set; }
        public object Tag { get; set; }
    }

    public class ResultRow
    {
        public string Status { get; set; }
        public string Action { get; set; }
        public string ObjectType { get; set; }
        public string Name { get; set; }
        public string Message { get; set; }
        public string TargetId { get; set; }
        public string RequestId { get; set; }
        public string File { get; set; }
        public string Time { get; set; }
    }

    public class LogRow
    {
        public string Time { get; set; }
        public string Level { get; set; }
        public string Category { get; set; }
        public string Message { get; set; }
        public string Detail { get; set; }
        public string Glyph { get; set; }
    }

    public class ProfileRow
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Tenant { get; set; }
        public string AuthType { get; set; }
        public string Detail { get; set; }
        public string Warning { get; set; }
        public object Tag { get; set; }
    }

    public class NavItem
    {
        public string Id { get; set; }
        public string Title { get; set; }
        public string Glyph { get; set; }
        public string Section { get; set; }
        public bool IsHeader { get; set; }
        public string Count { get; set; }
        public object Tag { get; set; }
    }

    public static class JsonHelper
    {
        public static object Parse(string json)
        {
            if (string.IsNullOrWhiteSpace(json)) return null;
            var options = new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip,
                MaxDepth = 256
            };
            using (var doc = JsonDocument.Parse(json, options))
            {
                return Convert(doc.RootElement);
            }
        }

        private static object Convert(JsonElement el)
        {
            switch (el.ValueKind)
            {
                case JsonValueKind.Object:
                    var pso = new PSObject();
                    foreach (var prop in el.EnumerateObject())
                    {
                        var existing = pso.Properties[prop.Name];
                        var value = Convert(prop.Value);
                        if (existing != null) { existing.Value = value; }
                        else { pso.Properties.Add(new PSNoteProperty(prop.Name, value)); }
                    }
                    return pso;
                case JsonValueKind.Array:
                    var list = new List<object>();
                    foreach (var item in el.EnumerateArray()) list.Add(Convert(item));
                    return list.ToArray();
                case JsonValueKind.String:
                    return el.GetString();
                case JsonValueKind.Number:
                    long l;
                    if (el.TryGetInt64(out l))
                    {
                        if (l >= int.MinValue && l <= int.MaxValue) return (int)l;
                        return l;
                    }
                    decimal d;
                    if (el.TryGetDecimal(out d)) return d;
                    return el.GetDouble();
                case JsonValueKind.True: return true;
                case JsonValueKind.False: return false;
                default: return null;
            }
        }
    }
}
