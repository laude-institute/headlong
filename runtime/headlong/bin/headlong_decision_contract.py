"""Bounded, provider-independent decision request and result validation."""
import json
import math
import re

MAX_REQUEST = 24 * 1024
MAX_RESPONSE = 32 * 1024
MODEL = 'snap:2b'
MODEL_SHA256 = '9f1d51a72ab88b59d2739515c909f1c3d4b24906078d62d6d63d4921f300db97'


def encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':'))


def decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('duplicate_key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite')))


def validate_request(value):
    if not isinstance(value, dict) or set(value) - {'state', 'questions', 'model'}:
        raise ValueError('unsupported_fields')
    if value.get('model', MODEL) != MODEL:
        raise ValueError('unsupported_model')
    if not isinstance(value.get('state'), (str, list, dict)):
        raise ValueError('invalid_state')
    questions = value.get('questions')
    if not isinstance(questions, dict) or not 1 <= len(questions) <= 8:
        raise ValueError('expected_1_to_8_questions')
    for key, q in questions.items():
        if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', key):
            raise ValueError('invalid_question_id')
        if not isinstance(q, dict) or set(q) - {'type', 'instructions', 'criteria'}:
            raise ValueError('invalid_question')
        if not isinstance(q.get('instructions'), str) or not 1 <= len(q['instructions']) <= 3000:
            raise ValueError('invalid_instructions')
        kind, c = q.get('type'), q.get('criteria')
        if kind == 'choice':
            if not isinstance(c, dict) or not 2 <= len(c) <= 26 or any(
                    not isinstance(k, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', k)
                    or not isinstance(v, str) or len(v) > 1500 for k, v in c.items()):
                raise ValueError('invalid_choices')
        elif kind == 'score':
            if not isinstance(c, list) or not 2 <= len(c) <= 10 or any(
                    not isinstance(v, str) or len(v) > 1500 for v in c):
                raise ValueError('invalid_rubric')
        elif kind == 'noul':
            if c is not None and (not isinstance(c, dict) or set(c) - {'true', 'false'}
                                 or any(not isinstance(v, str) or len(v) > 1500 for v in c.values())):
                raise ValueError('invalid_noul')
        else:
            raise ValueError('invalid_type')
    result = {'state': value['state'], 'questions': questions, 'model': MODEL}
    if len(encode(result).encode()) > MAX_REQUEST:
        raise ValueError('request_too_large')
    return result


def number(value, low, high):
    if type(value) not in (float, int) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError('invalid_number')
    return value


def validate_answers(data, request, model=MODEL, require_complete=True):
    if not isinstance(data, dict) or data.get('model') != model:
        raise ValueError('wrong_model')
    if data.get('state_truncated') is True or (require_complete and data.get('state_truncated') is not False):
        raise ValueError('missing_or_truncated_state')
    rows = data.get('answers')
    if not isinstance(rows, dict) or set(rows) != set(request['questions']):
        raise ValueError('missing_or_extra_answers')
    answers = {}
    for key, q in request['questions'].items():
        row = rows[key]
        kind = q['type']
        if not isinstance(row, dict) or row.get('type') != kind:
            raise ValueError('wrong_answer_type')
        answer = {'type': kind}
        if kind == 'noul':
            answer['noul'] = number(row.get('noul'), 0, 1)
        else:
            labels = list(q['criteria']) if kind == 'choice' else [str(i) for i in range(len(q['criteria']))]
            probs = row.get('probabilities')
            if not isinstance(probs, dict) or set(probs) != set(labels):
                raise ValueError('wrong_probability_labels')
            answer['probabilities'] = {k: number(probs[k], 0, 1) for k in labels}
            if abs(sum(answer['probabilities'].values()) - 1) > .01:
                raise ValueError('wrong_probability_sum')
            answer['confidence'] = number(row.get('confidence'), 0, 1)
            if kind == 'choice':
                if row.get('choice') not in labels:
                    raise ValueError('unknown_choice')
                answer['choice'] = row['choice']
            else:
                answer['score'] = number(row.get('score'), 0, len(labels) - 1)
                answer['legend'] = dict(zip(labels, q['criteria']))
        answers[key] = answer
    return answers
