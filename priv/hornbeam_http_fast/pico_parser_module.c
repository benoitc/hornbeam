/*
 * Copyright 2026 Benoit Chesneau
 * Licensed under Apache 2.0
 *
 * Python C extension for picohttpparser.
 * Provides fast HTTP request/response parsing using SIMD when available.
 */

#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include "picohttpparser/picohttpparser.h"

#define MAX_HEADERS 100

/* Forward declarations */
static PyObject *PicoError;
static PyObject *IncompleteError;

/*
 * parse_request(data: bytes, last_len: int = 0) -> dict
 *
 * Parse HTTP request and return dict with:
 *   method, path, minor_version, headers, consumed
 */
static PyObject *
pico_parse_request(PyObject *self, PyObject *args, PyObject *kwargs)
{
    static char *kwlist[] = {"data", "last_len", NULL};
    Py_buffer buf;
    Py_ssize_t last_len = 0;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "y*|n", kwlist,
                                     &buf, &last_len)) {
        return NULL;
    }

    const char *method;
    size_t method_len;
    const char *path;
    size_t path_len;
    int minor_version;
    struct phr_header headers[MAX_HEADERS];
    size_t num_headers = MAX_HEADERS;

    int ret = phr_parse_request(
        buf.buf, buf.len,
        &method, &method_len,
        &path, &path_len,
        &minor_version,
        headers, &num_headers,
        (size_t)last_len
    );

    PyBuffer_Release(&buf);

    if (ret > 0) {
        /* Success - build result dict */
        PyObject *result = PyDict_New();
        if (!result) return NULL;

        PyObject *py_method = PyBytes_FromStringAndSize(method, method_len);
        PyObject *py_path = PyBytes_FromStringAndSize(path, path_len);
        PyObject *py_version = PyLong_FromLong(minor_version);
        PyObject *py_consumed = PyLong_FromLong(ret);

        /* Build headers list */
        PyObject *py_headers = PyList_New(num_headers);
        if (!py_headers) {
            Py_DECREF(result);
            Py_XDECREF(py_method);
            Py_XDECREF(py_path);
            Py_XDECREF(py_version);
            Py_XDECREF(py_consumed);
            return NULL;
        }

        for (size_t i = 0; i < num_headers; i++) {
            PyObject *name = PyBytes_FromStringAndSize(
                headers[i].name, headers[i].name_len);
            PyObject *value = PyBytes_FromStringAndSize(
                headers[i].value, headers[i].value_len);
            PyObject *tuple = PyTuple_Pack(2, name, value);
            Py_DECREF(name);
            Py_DECREF(value);
            PyList_SET_ITEM(py_headers, i, tuple);
        }

        PyDict_SetItemString(result, "method", py_method);
        PyDict_SetItemString(result, "path", py_path);
        PyDict_SetItemString(result, "minor_version", py_version);
        PyDict_SetItemString(result, "headers", py_headers);
        PyDict_SetItemString(result, "consumed", py_consumed);

        Py_DECREF(py_method);
        Py_DECREF(py_path);
        Py_DECREF(py_version);
        Py_DECREF(py_headers);
        Py_DECREF(py_consumed);

        return result;
    }
    else if (ret == -2) {
        PyErr_SetString(IncompleteError, "Incomplete request, need more data");
        return NULL;
    }
    else {
        PyErr_SetString(PicoError, "Invalid HTTP request");
        return NULL;
    }
}

/*
 * parse_response(data: bytes, last_len: int = 0) -> dict
 */
static PyObject *
pico_parse_response(PyObject *self, PyObject *args, PyObject *kwargs)
{
    static char *kwlist[] = {"data", "last_len", NULL};
    Py_buffer buf;
    Py_ssize_t last_len = 0;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "y*|n", kwlist,
                                     &buf, &last_len)) {
        return NULL;
    }

    int minor_version;
    int status;
    const char *msg;
    size_t msg_len;
    struct phr_header headers[MAX_HEADERS];
    size_t num_headers = MAX_HEADERS;

    int ret = phr_parse_response(
        buf.buf, buf.len,
        &minor_version,
        &status,
        &msg, &msg_len,
        headers, &num_headers,
        (size_t)last_len
    );

    PyBuffer_Release(&buf);

    if (ret > 0) {
        PyObject *result = PyDict_New();
        if (!result) return NULL;

        PyObject *py_status = PyLong_FromLong(status);
        PyObject *py_message = PyBytes_FromStringAndSize(msg, msg_len);
        PyObject *py_version = PyLong_FromLong(minor_version);
        PyObject *py_consumed = PyLong_FromLong(ret);

        PyObject *py_headers = PyList_New(num_headers);
        for (size_t i = 0; i < num_headers; i++) {
            PyObject *name = PyBytes_FromStringAndSize(
                headers[i].name, headers[i].name_len);
            PyObject *value = PyBytes_FromStringAndSize(
                headers[i].value, headers[i].value_len);
            PyObject *tuple = PyTuple_Pack(2, name, value);
            Py_DECREF(name);
            Py_DECREF(value);
            PyList_SET_ITEM(py_headers, i, tuple);
        }

        PyDict_SetItemString(result, "status", py_status);
        PyDict_SetItemString(result, "message", py_message);
        PyDict_SetItemString(result, "minor_version", py_version);
        PyDict_SetItemString(result, "headers", py_headers);
        PyDict_SetItemString(result, "consumed", py_consumed);

        Py_DECREF(py_status);
        Py_DECREF(py_message);
        Py_DECREF(py_version);
        Py_DECREF(py_headers);
        Py_DECREF(py_consumed);

        return result;
    }
    else if (ret == -2) {
        PyErr_SetString(IncompleteError, "Incomplete response, need more data");
        return NULL;
    }
    else {
        PyErr_SetString(PicoError, "Invalid HTTP response");
        return NULL;
    }
}

/*
 * parse_headers(data: bytes, last_len: int = 0) -> list
 */
static PyObject *
pico_parse_headers(PyObject *self, PyObject *args, PyObject *kwargs)
{
    static char *kwlist[] = {"data", "last_len", NULL};
    Py_buffer buf;
    Py_ssize_t last_len = 0;

    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "y*|n", kwlist,
                                     &buf, &last_len)) {
        return NULL;
    }

    struct phr_header headers[MAX_HEADERS];
    size_t num_headers = MAX_HEADERS;

    int ret = phr_parse_headers(
        buf.buf, buf.len,
        headers, &num_headers,
        (size_t)last_len
    );

    PyBuffer_Release(&buf);

    if (ret > 0) {
        PyObject *py_headers = PyList_New(num_headers);
        for (size_t i = 0; i < num_headers; i++) {
            PyObject *name = PyBytes_FromStringAndSize(
                headers[i].name, headers[i].name_len);
            PyObject *value = PyBytes_FromStringAndSize(
                headers[i].value, headers[i].value_len);
            PyObject *tuple = PyTuple_Pack(2, name, value);
            Py_DECREF(name);
            Py_DECREF(value);
            PyList_SET_ITEM(py_headers, i, tuple);
        }
        return py_headers;
    }
    else if (ret == -2) {
        PyErr_SetString(IncompleteError, "Incomplete headers");
        return NULL;
    }
    else {
        PyErr_SetString(PicoError, "Invalid headers");
        return NULL;
    }
}

/* Module method table */
static PyMethodDef pico_methods[] = {
    {"parse_request", (PyCFunction)pico_parse_request,
     METH_VARARGS | METH_KEYWORDS,
     "Parse HTTP request.\n\n"
     "Args:\n"
     "    data: Raw HTTP request bytes\n"
     "    last_len: Previously parsed length for incremental parsing\n\n"
     "Returns:\n"
     "    dict with method, path, minor_version, headers, consumed"},

    {"parse_response", (PyCFunction)pico_parse_response,
     METH_VARARGS | METH_KEYWORDS,
     "Parse HTTP response.\n\n"
     "Args:\n"
     "    data: Raw HTTP response bytes\n"
     "    last_len: Previously parsed length for incremental parsing\n\n"
     "Returns:\n"
     "    dict with status, message, minor_version, headers, consumed"},

    {"parse_headers", (PyCFunction)pico_parse_headers,
     METH_VARARGS | METH_KEYWORDS,
     "Parse HTTP headers only.\n\n"
     "Args:\n"
     "    data: Raw header bytes\n"
     "    last_len: Previously parsed length\n\n"
     "Returns:\n"
     "    list of (name, value) tuples"},

    {NULL, NULL, 0, NULL}
};

/* Module definition */
static struct PyModuleDef pico_module = {
    PyModuleDef_HEAD_INIT,
    "pico_parser",
    "Fast HTTP parser using picohttpparser.\n\n"
    "This module provides high-performance HTTP parsing using the\n"
    "picohttpparser library with SIMD optimizations.",
    -1,
    pico_methods
};

/* Module initialization */
PyMODINIT_FUNC
PyInit_pico_parser(void)
{
    PyObject *m = PyModule_Create(&pico_module);
    if (m == NULL) return NULL;

    /* Create exception types */
    PicoError = PyErr_NewException("pico_parser.ParseError", PyExc_ValueError, NULL);
    Py_INCREF(PicoError);
    PyModule_AddObject(m, "ParseError", PicoError);

    IncompleteError = PyErr_NewException("pico_parser.IncompleteError", PyExc_Exception, NULL);
    Py_INCREF(IncompleteError);
    PyModule_AddObject(m, "IncompleteError", IncompleteError);

    return m;
}
