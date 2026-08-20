#!/usr/bin/env python3
"""Sintetiza a fala da Clarisse em pedacos, para a voz comecar quase na hora.

Recebe uma pasta com segmentos.txt (um segmento por linha) e escreve seg000.mp3,
seg001.mp3, e assim por diante. Cada mp3 ganha um seg000.ok depois de fechado, e
e essa sentinela que autoriza o PowerShell a toca-lo: um mp3 ainda em gravacao
abre no player com duracao errada e corta a fala no meio.

Por que existe em vez de chamar o executavel do edge-tts: o CLI grava o audio
inteiro antes de devolver o controle, o que custa 33 segundos de silencio num
resumo de mil e quinhentos caracteres. A biblioteca entrega o audio em fluxo, e
o primeiro pedaco fica pronto em cerca de um segundo.
"""
import argparse
import asyncio
import os
import sys

import edge_tts


def escrever_erro(pasta, msg):
    with open(os.path.join(pasta, 'erro.txt'), 'w', encoding='utf-8') as f:
        f.write(msg)


def tocar_sentinela(caminho):
    open(caminho, 'w').close()


async def sintetizar(args):
    with open(os.path.join(args.pasta, 'segmentos.txt'), encoding='utf-8') as f:
        segmentos = [linha.strip() for linha in f if linha.strip()]

    for i, texto in enumerate(segmentos):
        # O PowerShell cria parar.txt quando o usuario cancela: sem isso a
        # sintese seguiria baixando audio que ninguem vai ouvir.
        if os.path.exists(os.path.join(args.pasta, 'parar.txt')):
            return

        mp3 = os.path.join(args.pasta, 'seg%03d.mp3' % i)
        fala = edge_tts.Communicate(texto, args.voz, rate=args.rate, volume=args.volume)
        with open(mp3, 'wb') as destino:
            async for pedaco in fala.stream():
                if pedaco['type'] == 'audio':
                    destino.write(pedaco['data'])

        if os.path.getsize(mp3) < 200:
            escrever_erro(args.pasta, 'segmento %d veio sem audio' % i)
            return

        tocar_sentinela(os.path.join(args.pasta, 'seg%03d.ok' % i))

    tocar_sentinela(os.path.join(args.pasta, 'fim.ok'))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--pasta', required=True)
    p.add_argument('--voz', required=True)
    p.add_argument('--rate', default='+0%')
    p.add_argument('--volume', default='+0%')
    args = p.parse_args()

    # Fronteira de sistema: qualquer falha daqui tem de virar erro.txt, senao o
    # PowerShell ficaria esperando um segmento que nunca vai chegar.
    try:
        asyncio.run(sintetizar(args))
    except Exception as e:
        escrever_erro(args.pasta, '%s: %s' % (type(e).__name__, e))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
