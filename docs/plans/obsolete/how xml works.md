# File A

This is how file a records are made. notice i flattened trasmissione into trasmissione_tipo and all informazionianagrafiche into a single table in file a parser. codice istitutodicura and progressivosdo are the identifiers of the sdo and are places as attributes of informazioni anagrafiche node. 
```xml
<flsaInformazioniAnagrafiche xmlns:xsi="http://www.w3.org/2001/XMLSchema">
    <aInformazioniAnagrafiche>
        <trasmissione>
            <tipo>I</tipo>
        </trasmissione>
        <informazioniAnagrafiche codiceIstitutoDiCura="15090100" progressivoSDO="25002347">
            <sesso>2</sesso>
            <dataNascita>1994-11-11</dataNascita>
            <livelloIstruzione>9</livelloIstruzione>
            <statoCivile>1</statoCivile>
            <comuneResidenza>063049</comuneResidenza>
            <quartiere>10</quartiere>
            <cittadinanza>100</cittadinanza>
            <identificativoPaziente>xxxxxxxxxxx</identificativoPaziente>
            <tipIdPazienteInVerVal>0</tipIdPazienteInVerVal>
            <regioneResidenza>150</regioneResidenza>
            <aslResidenza>204</aslResidenza>
            <cognome>xxxxx</cognome>
            <nome>xxxx</nome>
            <comuneNascita>063048</comuneNascita>
        </informazioniAnagrafiche>
    </aInformazioniAnagrafiche>
    ...
</flsaInformazioniAnagrafiche>
```

# File B

look at file B now. we onlyneed informazioniRicovero (we already parsed trasmissione in file A and this is the same information). we have codiceIstitutoDiCura="15090100" progressivoSDO="25002347" as our id. good. then there are a lot of other children that are not scalar. one is dimissione, that has to be flattened with all its children. then we have accessiindh. my best idea so far is to make this a list inside the informazioniricovero table. then this becomes triky.

## Diagnosi

Nodes:
- <diagnosiPrincipale> always present
- <diagnosiSecondarie> may be present or not, may be even more than 1. this is charactetrized by a numDiagnosiSecondaria="N" tag.
My idea is to make all diagnosi a new table (diagnosi) where all diagnosi are inside the same table
- diagnosi icd code
- diagnosi principale position (num diagnosi = 0)
- diagnosi secondarie position (num diagnosi 1+)

## procedure

Nodes:
- <interventoPrincipale> it may NOT be present. optional
- <interventiSecondari> optional
this table procedure would work wih the same logic of diagnosi with the only difference that it may not be generated and all nested non scalar children like chirurghi (they are max 3) and anestesista (max 1) are flattened inside the intervento.

```xml
<flsbInformazioniRicovero xmlns:xsi="http://www.w3.org/2001/XMLSchema">
<bInformazioniRicovero>
    <trasmissione>
        <tipo>I</tipo>
    </trasmissione>
    <informazioniRicovero codiceIstitutoDiCura="15090100" progressivoSDO="25002347">
        <regimeRicovero>2</regimeRicovero>
        <dataPrenotazione>2024-11-12</dataPrenotazione>
        <classePriorita>A</classePriorita>
        <dataRicovero>2025-01-14</dataRicovero>
        <oraRicovero>08:04</oraRicovero>
        <unitaOperativaAmmissione>150901003801</unitaOperativaAmmissione>
        <onereDegenza>1</onereDegenza>
        <provenienzaPaziente>04</provenienzaPaziente>
        <dimissione>
            <unitaOperativaDimissione>150901003801</unitaOperativaDimissione>
            <dataDimissioneMorte>2025-01-14</dataDimissioneMorte>
            <oraDimissioneMorte>18:27</oraDimissioneMorte>
            <modalitaDimissione>02</modalitaDimissione>
            <FlagICicloCura>0</FlagICicloCura>
        </dimissione>
        <motivoRicoveroRegimeDiurno>2</motivoRicoveroRegimeDiurno>
        <numGiornateRicoveroDiurno>1</numGiornateRicoveroDiurno>
        <AccessiInDH>
            <dataAccesso>2025-01-14</dataAccesso>
        </AccessiInDH>
        <diagnosiPrincipale>
            <diagnosiPrincipaleDimissione>87200</diagnosiPrincipaleDimissione>
            <diagnosiPrincipaleDimissioneAlRicovero>0</diagnosiPrincipaleDimissioneAlRicovero>
        </diagnosiPrincipale>
        <interventoPrincipale>
            <interventoPrincipale>1839</interventoPrincipale>
            <interventoPrincipaleEsterno>0</interventoPrincipaleEsterno>
            <dataInterventoPrincipale>2025-01-14</dataInterventoPrincipale>
            <oraInterventoPrincipale>14:20</oraInterventoPrincipale>
            <chirurgoInterventoPrincipale>aaaaaaaaaaaa</chirurgoInterventoPrincipale>
            <chirurgoInterventoPrincipale>bbbbbbbbbbbbbbb</chirurgoInterventoPrincipale>
            <anestesistaInterventoPrincipale>cccccccc</anestesistaInterventoPrincipale>
            <ckListSalaOperatoriaInterventoPrincipale>0</ckListSalaOperatoriaInterventoPrincipale>
            <Lateralita>1</Lateralita>
        </interventoPrincipale>
        <rilevazioneDolore>1</rilevazioneDolore>
        <DRG>55</DRG>
        <tariffa>1613.00</tariffa>
    </informazioniRicovero>
</bInformazioniRicovero>
<bInformazioniRicovero>
    <trasmissione>
        <tipo>I</tipo>
    </trasmissione>
    <informazioniRicovero codiceIstitutoDiCura="15090100" progressivoSDO="25003352">
        <regimeRicovero>1</regimeRicovero>
        <dataRicovero>2025-01-18</dataRicovero>
        <oraRicovero>10:54</oraRicovero>
        <unitaOperativaAmmissione>150901005801</unitaOperativaAmmissione>
        <onereDegenza>1</onereDegenza>
        <provenienzaPaziente>02</provenienzaPaziente>
        <tipoRicovero>2</tipoRicovero>
        <dimissione>
            <unitaOperativaDimissione>150901005801</unitaOperativaDimissione>
            <dataDimissioneMorte>2025-01-22</dataDimissioneMorte>
            <oraDimissioneMorte>15:50</oraDimissioneMorte>
            <modalitaDimissione>02</modalitaDimissione>
            <FlagICicloCura>1</FlagICicloCura>
        </dimissione>
        <diagnosiPrincipale>
            <diagnosiPrincipaleDimissione>2859</diagnosiPrincipaleDimissione>
            <diagnosiPrincipaleDimissioneAlRicovero>0</diagnosiPrincipaleDimissioneAlRicovero>
        </diagnosiPrincipale>
        <diagnosiSecondarie numDiagnosiSecondaria="1">
            <diagnosiSecondarieDimissione>V433</diagnosiSecondarieDimissione>
            <diagnosiSecondarieDimissioneAlRicovero>1</diagnosiSecondarieDimissioneAlRicovero>
        </diagnosiSecondarie>
        <interventoPrincipale>
            <interventoPrincipale>4523</interventoPrincipale>
            <interventoPrincipaleEsterno>0</interventoPrincipaleEsterno>
            <dataInterventoPrincipale>2025-01-20</dataInterventoPrincipale>
        </interventoPrincipale>
        <interventiSecondari numInterventoSecondario="01">
            <interventiSecondari>4413</interventiSecondari>
            <interventiSecondariEsterni>0</interventiSecondariEsterni>
            <dataInterventoSecondario>2025-01-18</dataInterventoSecondario>
        </interventiSecondari>
        <rilevazioneDolore>0</rilevazioneDolore>
        <DRG>395</DRG>
        <tariffa>1676.00</tariffa>
    </informazioniRicovero>
</bInformazioniRicovero>
...
</flsbInformazioniRicovero>
```

More info in docs/specifiche funzionali/
